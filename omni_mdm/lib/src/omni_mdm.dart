import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:omni_mdm_core/omni_mdm_core.dart';
import 'package:uuid/uuid.dart';

import 'actions/basic/device_info_action.dart';
import 'actions/omni_remote_action.dart';
import 'audit/omni_audit_client.dart';
import 'audit/omni_audit_event.dart';
import 'capabilities/capability_registry.dart';
import 'commands/command_dispatcher.dart';
import 'commands/command_hooks.dart';
import 'config/omni_mdm_config.dart';
import 'device/omni_device_identity.dart';
import 'enroll/omni_enroll_client.dart';
import 'flows/omni_flow_client.dart';
import 'flows/omni_flows.dart';
import 'mqtt/omni_mqtt_client.dart';
import 'observability/omni_observability_client.dart';
import 'session/omni_session.dart';
import 'session/omni_session_store.dart';
import 'sync/omni_sync_channel.dart';
import 'sync/omni_table_sync.dart';
import 'telemetry/omni_crash_reporter.dart';
import 'telemetry/omni_telemetry_client.dart';

export 'audit/omni_audit_event.dart';
export 'capabilities/mdm_capability.dart';
export 'config/omni_mdm_config.dart';
export 'sync/omni_sync_channel.dart';
export 'sync/omni_table_sync.dart';
export 'telemetry/omni_crash_reporter.dart';

/// Punto de entrada del SDK. `initialize` es fail-open hacia la app anfitriona.
abstract final class OmniMdm {
  static OmniMdmConfig? _config;
  static bool _initialized = false;
  static OmniAuditClient? _auditClient;
  static OmniEnrollClient? _enrollClient;
  static OmniFlowClient? _flowClient;
  static OmniTelemetryClient? _telemetryClient;
  static OmniCrashReporter? _crashReporter;
  static OmniFlows? _flows;
  static OmniMqttClient? _mqttClient;
  static CommandDispatcher? _commandDispatcher;
  static OmniObservabilityClient? _observabilityClient;
  static AppFailure? _lastEnrollError;
  static DateTime? _lastEnrollAt;
  static final OmniSession _session = OmniSession();
  static final OmniSessionStore _sessionStore = OmniSessionStore();
  static final CapabilityRegistry capabilities = CapabilityRegistry();
  static Completer<bool>? _refreshInFlight;
  static final Map<String, OmniRemoteAction> _actions = {
    'device_info': const DeviceInfoAction(),
  };
  static Timer? _actionPoll;

  static bool get isInitialized => _initialized;
  static bool get isEnrolled => _session.isEnrolled;
  static OmniMdmStatus get status => OmniMdmStatus(
        initialized: _initialized,
        enrolled: _session.isEnrolled,
        instanceId: _session.instanceId,
        businessId: _session.businessId,
        hardwareRole: _session.hardwareRole,
        lastEnrollError: _lastEnrollError,
        lastEnrollAt: _lastEnrollAt,
        endpoint: _config?.endpoint,
        mqttUrl: _config?.mqttUrl,
        mqttConfigured: _config?.mqttUrl != null && _config!.mqttUrl!.isNotEmpty,
        mqttConnected: _mqttClient?.isConnected ?? false,
        mqttLastError: _mqttClient?.lastError,
        tokenExpiresAt: _session.tokenExpiresAt,
      );
  static OmniFlows get flows => _flows ?? OmniFlows(OmniFlowClient(_config!, _session));

  /// Reinicializa con nueva config (p. ej. tras guardar en pantalla de ajustes).
  static Future<void> reinitialize(OmniMdmConfig config) async {
    _initialized = false;
    await _commandDispatcher?.stop();
    await _mqttClient?.disconnect();
    _commandDispatcher = null;
    _mqttClient = null;
    await initialize(config);
  }

  static Future<void> initialize(OmniMdmConfig config) async {
    try {
      _config = config;
      await _sessionStore.loadInto(_session);
      _enrollClient = OmniEnrollClient(config);
      _auditClient = OmniAuditClient(
        config,
        _session,
        onUnauthorized: () => refreshInstanceToken(force: true),
      );

      if (!config.syncOnly) {
        _mqttClient = OmniMqttClient(config, _session);
        _flowClient = OmniFlowClient(config, _session);
        _telemetryClient = OmniTelemetryClient(
          config,
          _session,
          _mqttClient!,
          onUnauthorized: () => refreshInstanceToken(force: true),
        );
        _crashReporter = OmniCrashReporter(config, _session);
        _observabilityClient = OmniObservabilityClient(
          config,
          _session,
          onUnauthorized: () => refreshInstanceToken(force: true),
        );
        _flows = OmniFlows(_flowClient!);
        _commandDispatcher = CommandDispatcher(_mqttClient!, capabilities);
        onCommandSucceeded = _onCommandSucceeded;
        _installCrashHooks();
      } else {
        _mqttClient = null;
        _flowClient = null;
        _telemetryClient = null;
        _crashReporter = null;
        _observabilityClient = null;
        _flows = null;
        _commandDispatcher = null;
      }

      _initialized = true;

      final hw = _session.hardwareFingerprint ?? await OmniDeviceIdentity.hardwareFingerprint();
      if (hw != null && hw.isNotEmpty) {
        _session.hardwareFingerprint = hw;
        // Siempre intenta mintar/renovar token al arranque (idempotente en backend).
        await refreshInstanceToken(
          force: !_session.isEnrolled || _session.needsTokenRefresh || _session.tokenExpiresAt == null,
        );
        await _sessionStore.save(_session);
      }

      if (_session.isEnrolled) {
        if (config.syncOnly) {
          unawaited(_pushAuthToNative());
        } else {
          unawaited(_startDeviceServices());
          unawaited(_reportStartupInventory());
          unawaited(_startEventAndActionLoops());
        }
      }

      if (kDebugMode) {
        debugPrint(
          '[omni_mdm] initialized endpoint=${config.endpoint} '
          'syncOnly=${config.syncOnly} '
          'enrolled=${_session.isEnrolled} expires=${_session.tokenExpiresAt}',
        );
      }
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint('[omni_mdm] initialize failed silently: $e\n$st');
      }
    }
  }

  /// Renueva el `instance_token` vía `POST /v1/enroll` (mismo fingerprint → reutiliza instancia).
  /// Sin intervención humana; coalesces concurrent refresh.
  static Future<bool> refreshInstanceToken({bool force = false}) async {
    if (!_initialized && _enrollClient == null) return false;

    if (!force && _session.isEnrolled && !_session.needsTokenRefresh) {
      return true;
    }

    final inFlight = _refreshInFlight;
    if (inFlight != null) return inFlight.future;

    final completer = Completer<bool>();
    _refreshInFlight = completer;

    try {
      final hw = _session.hardwareFingerprint ?? await OmniDeviceIdentity.hardwareFingerprint();
      if (hw == null || hw.isEmpty) {
        completer.complete(false);
        return false;
      }
      _session.hardwareFingerprint = hw;

      String? enrollmentToken;
      final provider = _config?.enrollmentTokenProvider;
      if (provider != null) {
        enrollmentToken = await provider();
      }

      final enrollRes = await _enrollClient!.enroll(
        hardwareFingerprint: hw,
        enrollmentToken: enrollmentToken,
      );

      final ok = enrollRes.when(
        ok: (value) {
          _session.instanceId = value.instanceId;
          _session.businessId = value.businessId;
          _session.instanceToken = value.instanceToken;
          _session.hardwareRole = value.hardwareRole;
          _session.tokenExpiresAt = value.tokenExpiresAt;
          _lastEnrollError = null;
          _lastEnrollAt = DateTime.now().toUtc();
          if (kDebugMode) {
            debugPrint(
              '[omni_mdm] instance token refreshed '
              'reused=${value.reusedInstance} expires=${value.tokenExpiresAt}',
            );
          }
          return true;
        },
        fail: (failure) {
          _lastEnrollError = failure;
          _lastEnrollAt = DateTime.now().toUtc();
          if (kDebugMode) {
            debugPrint(
              '[omni_mdm] token refresh failed: ${failure.code} ${failure.message}',
            );
          }
          return false;
        },
      );

      if (ok) {
        await _sessionStore.save(_session);
        await _pushAuthToNative();
      }
      completer.complete(ok);
      return ok;
    } catch (e) {
      if (kDebugMode) debugPrint('[omni_mdm] token refresh exception: $e');
      completer.complete(false);
      return false;
    } finally {
      _refreshInFlight = null;
    }
  }

  static Future<void> _startDeviceServices() async {
    // Conecta MQTT de inmediato para que el estado UI refleje "conectado".
    final mqttOk = await _mqttClient?.ensureConnected() ?? false;
    if (kDebugMode) {
      debugPrint(
        '[omni_mdm] mqtt ensureConnected=$mqttOk '
        'error=${_mqttClient?.lastError}',
      );
    }
    await _commandDispatcher?.start();
    await _publishManifest();
    unawaited(_telemetryClient?.sendHeartbeat());
  }

  /// Fuerza (re)conexión MQTT — útil desde pantalla de configuración.
  static Future<bool> connectMqtt() async {
    if (!_initialized || _config?.syncOnly == true) return false;
    if (!_session.isEnrolled) {
      final enrolled = await refreshInstanceToken(force: true);
      if (!enrolled) return false;
    }
    final ok = await _mqttClient?.ensureConnected() ?? false;
    if (ok) {
      unawaited(_commandDispatcher?.start());
    }
    return ok;
  }

  static Future<void> _onCommandSucceeded(
    String capability,
    Map<String, dynamic> result,
  ) async {
    if (capability == 'DEVICE_INFO' && result.isNotEmpty) {
      await _observabilityClient?.sendDeviceInventory(result, trigger: 'command');
    }
  }

  static Future<void> _publishManifest() async {
    final manifest = capabilities.toManifest();
    await _commandDispatcher?.publishManifest();
    final endpoint = _config?.endpoint;
    if (endpoint == null) return;

    Future<int?> postOnce() async {
      final token = _session.instanceToken;
      if (token == null) return null;
      try {
        final uri = Uri.parse('$endpoint/v1/ingest/manifest');
        final client = HttpClient();
        try {
          final req = await client.postUrl(uri);
          req.headers.set('Content-Type', 'application/json');
          _config?.applyTunnelHeaders(req);
          req.headers.set('Authorization', 'Bearer $token');
          req.add(utf8.encode(jsonEncode(manifest)));
          final res = await req.close();
          return res.statusCode;
        } finally {
          client.close(force: true);
        }
      } catch (e) {
        if (kDebugMode) debugPrint('[omni_mdm] manifest http ingest failed: $e');
        return null;
      }
    }

    var status = await postOnce();
    if (status == 401) {
      final refreshed = await refreshInstanceToken(force: true);
      if (refreshed) status = await postOnce();
    }
  }

  static void _installCrashHooks() {
    final reporter = _crashReporter;
    if (reporter == null) return;
    final prevFlutter = FlutterError.onError;
    FlutterError.onError = (details) {
      unawaited(reporter.reportFlutterError(details));
      prevFlutter?.call(details);
    };
    PlatformDispatcher.instance.onError = (error, stack) {
      unawaited(reporter.reportError(error, stack));
      return false;
    };
  }

  static Result<OmniMdmConfig> requireConfig() {
    final cfg = _config;
    if (cfg == null || !_initialized) {
      return resultFail(
        const AppFailure(
          code: 'sdk_not_initialized',
          message: 'Call OmniMdm.initialize first',
        ),
      );
    }
    return resultOk(cfg);
  }

  static Future<Result<void>> ingestAuditEvents(List<OmniAuditEvent> events) async {
    try {
      final client = _auditClient;
      if (client == null || !_initialized) {
        return resultFail(const AppFailure(
          code: 'sdk_not_initialized',
          message: 'Call OmniMdm.initialize first',
        ));
      }
      if (_session.needsTokenRefresh) {
        await refreshInstanceToken();
      }
      return client.sendEvents(events);
    } catch (e) {
      if (kDebugMode) debugPrint('[omni_mdm] ingestAuditEvents swallowed: $e');
      return resultFail(AppFailure(code: 'ingest_exception', message: e.toString()));
    }
  }

  static Future<void> _reportStartupInventory() async {
    try {
      final raw = await OmniDeviceIdentity.collectDeviceInfo();
      if (raw != null) {
        await _observabilityClient?.sendDeviceInventory(raw, trigger: 'app_start');
      }
    } catch (e) {
      if (kDebugMode) debugPrint('[omni_mdm] startup inventory failed: $e');
    }
  }

  static Future<Result<void>> reportDeviceInventory(
    Map<String, dynamic> inventory, {
    String trigger = 'app_start',
  }) async {
    final client = _observabilityClient;
    if (client == null || !_initialized) {
      return resultFail(const AppFailure(
        code: 'sdk_not_initialized',
        message: 'Call OmniMdm.initialize first',
      ));
    }
    if (!_session.isEnrolled) {
      final refreshed = await refreshInstanceToken(force: true);
      if (!refreshed) {
        return resultFail(const AppFailure(
          code: 'not_enrolled',
          message: 'Device not enrolled in MDM',
        ));
      }
    } else if (_session.needsTokenRefresh) {
      await refreshInstanceToken();
    }
    return client.sendDeviceInventory(inventory, trigger: trigger);
  }

  static Future<void> reportAuthEvent({
    required String clientEventId,
    required String eventType,
    String? businessUserRef,
    String? displayName,
    String? failureCode,
    String? failureMessage,
    Map<String, dynamic>? metadata,
  }) async {
    if (_session.needsTokenRefresh) {
      await refreshInstanceToken();
    }
    await _observabilityClient?.sendAuthEvents([
      {
        'client_event_id': clientEventId,
        'event_type': eventType,
        if (businessUserRef != null) 'business_user_ref': businessUserRef,
        if (displayName != null) 'display_name': displayName,
        if (failureCode != null) 'failure_code': failureCode,
        if (failureMessage != null) 'failure_message': failureMessage,
        if (metadata != null) 'metadata': metadata,
        'observed_at': DateTime.now().toUtc().toIso8601String(),
      },
    ]);
  }

  static Future<Result<Map<String, dynamic>>> probeMdmHealth() async {
    final client = _observabilityClient;
    if (client == null) {
      return resultFail(const AppFailure(
        code: 'sdk_not_initialized',
        message: 'Call OmniMdm.initialize first',
      ));
    }
    return client.probeHealth();
  }

  /// Heartbeat de telemetría (MQTT con fallback HTTP) + touch de presencia HTTP.
  static Future<void> sendHeartbeat({Map<String, dynamic>? payload}) async {
    if (_session.needsTokenRefresh) {
      await refreshInstanceToken();
    }
    await _telemetryClient?.sendHeartbeat(payload: payload);
  }

  static Future<void> sendMetric(
    String metricKey,
    double value, {
    Map<String, dynamic>? payload,
  }) async {
    if (_session.needsTokenRefresh) {
      await refreshInstanceToken();
    }
    await _telemetryClient?.sendMetric(metricKey, value, payload: payload);
  }

  static Future<Result<void>> ingestAuditEvent(OmniAuditEvent event) =>
      ingestAuditEvents([event]);

  /// INSERT local en la tabla del plugin. El table-sync (Kotlin) sube el lote.
  static Future<void> logEvent({
    required String type,
    required String name,
    Map<String, dynamic> payload = const {},
  }) async {
    if (!_initialized) return;
    try {
      await OmniTableSync.enqueuePluginEvent(
        id: const Uuid().v4(),
        createdAt: DateTime.now().toUtc().toIso8601String(),
        eventType: type,
        eventAction: name,
        payloadJson: jsonEncode(payload),
      );
    } catch (e) {
      if (kDebugMode) debugPrint('[omni_mdm] logEvent fail-open: $e');
    }
  }

  /// El desarrollador de la app anfitriona registra acciones abstractas (p. ej. query SQLite).
  static void registerHostAction(OmniRemoteAction action) {
    _actions[action.actionKey] = action;
  }

  /// Declara canales MDM (`PUSH_ONLY` audit, `PULL_ONLY` settings). Fail-open.
  static Future<void> configureSyncChannels(
    List<OmniSyncChannel> channels, {
    OmniPushBatchHost? host,
  }) async {
    try {
      final cfg = _config;
      if (cfg == null || !_initialized) return;
      if (host != null) {
        OmniTableSync.bindHost(host);
      }
      await OmniTableSync.configure(
        endpoint: cfg.endpoint,
        appKey: cfg.appKey,
        appSecret: cfg.appSecret,
        token: _session.instanceToken,
        channels: channels,
        headers: cfg.extraHttpHeaders(),
        syncIntervalSec: cfg.syncIntervalSec,
      );
    } catch (e) {
      if (kDebugMode) debugPrint('[omni_mdm] configureSyncChannels: $e');
    }
  }

  /// Agenda el ciclo periódico (default 5 min) y ejecuta la primera pasada de inmediato.
  static Future<void> scheduleTableSync() async {
    try {
      await OmniTableSync.schedule();
    } catch (e) {
      if (kDebugMode) debugPrint('[omni_mdm] scheduleTableSync: $e');
    }
  }

  /// Sync inmediato al resume/apertura; reinicia circuit breaker y reprograma el ciclo.
  static Future<void> triggerTableSyncNow() async {
    await _runTableSyncWithReenroll(resetCircuit: true);
    try {
      await OmniTableSync.schedule();
    } catch (e) {
      if (kDebugMode) debugPrint('[omni_mdm] scheduleTableSync after trigger: $e');
    }
  }

  /// Una pasada ahora (diagnóstico / soporte). Pull settings y luego push audit.
  static Future<Map<String, dynamic>> runSynchronized() {
    return _runTableSyncWithReenroll();
  }

  static Future<Map<String, dynamic>> _runTableSyncWithReenroll({bool resetCircuit = false}) async {
    try {
      var result = await OmniTableSync.runSynchronized(resetCircuit: resetCircuit);
      if (_isAuthSyncError(result)) {
        final refreshed = await refreshInstanceToken(force: true);
        if (refreshed) {
          await _pushAuthToNative();
          if (_config != null) {
            await OmniTableSync.configure(
              endpoint: _config!.endpoint,
              appKey: _config!.appKey,
              appSecret: _config!.appSecret,
              token: _session.instanceToken,
              channels: const [],
              headers: _config!.extraHttpHeaders(),
              syncIntervalSec: _config!.syncIntervalSec,
            );
          }
          result = await OmniTableSync.runSynchronized(resetCircuit: true);
        }
      }
      return result;
    } catch (e) {
      if (kDebugMode) debugPrint('[omni_mdm] table sync: $e');
      return {'ok': false, 'error': e.toString()};
    }
  }

  static bool _isAuthSyncError(Map<String, dynamic> result) {
    if (result['ok'] == true) return false;
    final err = result['error']?.toString().toLowerCase() ?? '';
    return err.contains('401') ||
        err.contains('403') ||
        err.contains('unauthorized') ||
        err.contains('instance_not_enrolled') ||
        err.contains('device not enrolled');
  }

  static Future<void> _pushAuthToNative() async {
    final cfg = _config;
    if (cfg == null || !_initialized) return;
    try {
      await OmniTableSync.configure(
        endpoint: cfg.endpoint,
        appKey: cfg.appKey,
        appSecret: cfg.appSecret,
        token: _session.instanceToken,
        channels: const [],
        headers: cfg.extraHttpHeaders(),
        syncIntervalSec: cfg.syncIntervalSec,
      );
    } catch (_) {}
  }

  static Future<void> _startEventAndActionLoops() async {
    final cfg = _config;
    if (cfg == null || cfg.syncOnly) return;
    await OmniTableSync.schedule();
    _actionPoll?.cancel();
    _actionPoll = Timer.periodic(const Duration(seconds: 30), (_) {
      unawaited(_pollRemoteActions());
    });
    unawaited(_pollRemoteActions());
  }

  static Future<void> _pollRemoteActions() async {
    final cfg = _config;
    final token = _session.instanceToken;
    if (cfg == null || token == null || token.isEmpty) return;
    final client = OmniMdmConfig.createHttpClient();
    try {
      final uri = Uri.parse('${cfg.endpoint}/v1/sdk/pending-actions');
      final req = await client.getUrl(uri);
      req.headers.set('Authorization', 'Bearer $token');
      cfg.applyTunnelHeaders(req);
      final resp = await req.close();
      final body = await resp.transform(utf8.decoder).join();
      if (resp.statusCode < 200 || resp.statusCode >= 300) return;
      final json = jsonDecode(body);
      final items = (json is Map ? json['items'] : null);
      if (items is! List) return;
      for (final raw in items) {
        if (raw is! Map) continue;
        final id = raw['id']?.toString() ?? '';
        final key = raw['action_key']?.toString() ?? '';
        final params = raw['params'] is Map
            ? Map<String, dynamic>.from(raw['params'] as Map)
            : <String, dynamic>{};
        final handler = _actions[key];
        if (id.isEmpty) continue;
        if (handler == null) {
          await _completeRemoteAction(cfg, token, id, 'failed', {
            'error': 'action_not_registered',
            'action_key': key,
          });
          continue;
        }
        final result = await handler.execute(params);
        await result.when(
          ok: (value) => _completeRemoteAction(cfg, token, id, 'succeeded', value),
          fail: (err) => _completeRemoteAction(cfg, token, id, 'failed', {
            'code': err.code,
            'message': err.message,
          }),
        );
      }
    } catch (e) {
      if (kDebugMode) debugPrint('[omni_mdm] poll actions: $e');
    } finally {
      client.close();
    }
  }

  static Future<void> _completeRemoteAction(
    OmniMdmConfig cfg,
    String token,
    String actionId,
    String status,
    Map<String, dynamic> result,
  ) async {
    final client = OmniMdmConfig.createHttpClient();
    try {
      final uri = Uri.parse('${cfg.endpoint}/v1/sdk/actions/$actionId/result');
      final req = await client.postUrl(uri);
      req.headers.set('Authorization', 'Bearer $token');
      req.headers.contentType = ContentType.json;
      cfg.applyTunnelHeaders(req);
      req.add(utf8.encode(jsonEncode({'status': status, 'result': result})));
      await (await req.close()).drain<void>();
    } catch (_) {
    } finally {
      client.close();
    }
  }
}
