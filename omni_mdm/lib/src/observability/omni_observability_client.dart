import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:omni_mdm_core/omni_mdm_core.dart';

import '../auth/omni_auth_refresh.dart';
import '../config/omni_mdm_config.dart';
import '../session/omni_session.dart';

/// Estado observable de integración MDM (para UI de diagnóstico).
class OmniMdmStatus {
  const OmniMdmStatus({
    required this.initialized,
    required this.enrolled,
    this.instanceId,
    this.businessId,
    this.hardwareRole,
    this.lastEnrollError,
    this.lastEnrollAt,
    this.endpoint,
    this.mqttUrl,
    this.mqttConfigured = false,
    this.mqttConnected = false,
    this.mqttLastError,
    this.tokenExpiresAt,
  });

  final bool initialized;
  final bool enrolled;
  final String? instanceId;
  final String? businessId;
  final String? hardwareRole;
  final AppFailure? lastEnrollError;
  final DateTime? lastEnrollAt;
  final String? endpoint;
  final String? mqttUrl;
  final bool mqttConfigured;
  final bool mqttConnected;
  final String? mqttLastError;
  final DateTime? tokenExpiresAt;

  String get integrationLabel {
    if (!initialized) return 'SDK no inicializado';
    if (enrolled) return 'Integrado al MDM';
    if (lastEnrollError != null) {
      return 'Error: ${lastEnrollError!.code}';
    }
    return 'No enrolado';
  }

  String get mqttLabel {
    if (!mqttConfigured) return 'solo HTTP (MQTT no configurado)';
    if (mqttConnected) return 'conectado';
    if (mqttLastError != null && mqttLastError!.isNotEmpty) {
      return 'sin conexión · $mqttLastError';
    }
    return 'configurado, sin conexión';
  }
}

class OmniObservabilityClient {
  OmniObservabilityClient(
    this._config,
    this._session, {
    OmniAuthRefresh? onUnauthorized,
  }) : _onUnauthorized = onUnauthorized;

  final OmniMdmConfig _config;
  final OmniSession _session;
  final OmniAuthRefresh? _onUnauthorized;

  Future<Result<void>> sendDeviceInventory(
    Map<String, dynamic> inventory, {
    String trigger = 'app_start',
  }) async {
    return _post('/v1/ingest/device-inventory', {
      'inventory': inventory,
      'trigger': trigger,
      'observed_at': DateTime.now().toUtc().toIso8601String(),
    });
  }

  Future<Result<void>> sendAuthEvents(List<Map<String, dynamic>> events) async {
    return _post('/v1/ingest/auth-events', {'events': events});
  }

  Future<Result<void>> sendIntegrationEvent({
    required String eventType,
    required String status,
    String? errorCode,
    String? errorMessage,
    Map<String, dynamic>? metadata,
    String? clientEventId,
  }) async {
    return _post('/v1/ingest/integration-events', {
      'event_type': eventType,
      'status': status,
      if (errorCode != null) 'error_code': errorCode,
      if (errorMessage != null) 'error_message': errorMessage,
      if (metadata != null) 'metadata': metadata,
      if (clientEventId != null) 'client_event_id': clientEventId,
      'observed_at': DateTime.now().toUtc().toIso8601String(),
    });
  }

  Future<Result<Map<String, dynamic>>> probeHealth() async {
    try {
      final uri = Uri.parse('${_config.endpoint}/v1/health');
      final client = HttpClient();
      try {
        final req = await client.getUrl(uri);
        _config.applyTunnelHeaders(req);
        final res = await req.close();
        final body = await res.transform(utf8.decoder).join();
        if (res.statusCode >= 200 && res.statusCode < 300) {
          return resultOk({'status_code': res.statusCode, 'body': body});
        }
        return resultFail(AppFailure(
          code: 'mdm_health_${res.statusCode}',
          message: body,
        ));
      } finally {
        client.close(force: true);
      }
    } catch (e) {
      return resultFail(AppFailure(code: 'mdm_health_network', message: e.toString()));
    }
  }

  Future<Result<void>> _post(String path, Map<String, dynamic> body) async {
    Future<Result<void>> attempt() => _postOnce(path, body);
    final first = await attempt();
    if (first is Ok<void>) return first;

    final failure = (first as Fail<void>).failure;
    final refresh = _onUnauthorized;
    if (!isUnauthorizedFailure(failure) || refresh == null) {
      return first;
    }
    final refreshed = await refresh();
    if (!refreshed) return first;
    return attempt();
  }

  Future<Result<void>> _postOnce(String path, Map<String, dynamic> body) async {
    final token = _session.instanceToken;
    if (token == null) {
      return resultFail(const AppFailure(
        code: 'not_enrolled',
        message: 'Device not enrolled',
      ));
    }
    try {
      final uri = Uri.parse('${_config.endpoint}$path');
      final client = HttpClient();
      try {
        final req = await client.postUrl(uri);
        req.headers.set('Content-Type', 'application/json');
        _config.applyTunnelHeaders(req);
        req.headers.set('Authorization', 'Bearer $token');
        req.add(utf8.encode(jsonEncode(body)));
        final res = await req.close();
        if (res.statusCode >= 200 && res.statusCode < 300) {
          return resultOk(null);
        }
        final responseBody = await res.transform(utf8.decoder).join();
        return resultFail(AppFailure(
          code: 'obs_http_${res.statusCode}',
          message: responseBody,
        ));
      } finally {
        client.close(force: true);
      }
    } catch (e) {
      if (kDebugMode) debugPrint('[omni_mdm] observability post failed: $e');
      return resultFail(AppFailure(code: 'obs_network', message: e.toString()));
    }
  }
}
