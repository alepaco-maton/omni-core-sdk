import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:omni_mdm_core/omni_mdm_core.dart';

import '../auth/omni_auth_refresh.dart';
import '../config/omni_mdm_config.dart';
import '../mqtt/omni_mqtt_client.dart';
import '../session/omni_session.dart';

class OmniTelemetryClient {
  OmniTelemetryClient(
    this._config,
    this._session,
    this._mqtt, {
    OmniAuthRefresh? onUnauthorized,
  }) : _onUnauthorized = onUnauthorized;

  final OmniMdmConfig _config;
  final OmniSession _session;
  final OmniMqttClient _mqtt;
  final OmniAuthRefresh? _onUnauthorized;

  Future<Result<void>> sendHeartbeat({Map<String, dynamic>? payload}) async {
    await _touchPresenceHeartbeat();

    return sendMetric(
      'heartbeat',
      1,
      payload: {
        'role': _session.hardwareRole,
        ...?payload,
      },
    );
  }

  /// Actualiza `app_instances.last_heartbeat_at` (lo que muestra el dashboard).
  Future<void> _touchPresenceHeartbeat() async {
    Future<int?> postOnce() async {
      final token = _session.instanceToken;
      if (token == null) return null;
      try {
        final uri = Uri.parse('${_config.endpoint}/v1/ingest/heartbeat');
        final client = HttpClient();
        try {
          final req = await client.postUrl(uri);
          req.headers.set('Content-Type', 'application/json');
          _config.applyTunnelHeaders(req);
          req.headers.set('Authorization', 'Bearer $token');
          req.add(utf8.encode('{}'));
          final res = await req.close();
          return res.statusCode;
        } finally {
          client.close(force: true);
        }
      } catch (e) {
        if (kDebugMode) debugPrint('[omni_mdm] presence heartbeat failed: $e');
        return null;
      }
    }

    var status = await postOnce();
    final refresh = _onUnauthorized;
    if (status == 401 && refresh != null) {
      final refreshed = await refresh();
      if (refreshed) {
        status = await postOnce();
      }
    }
    if (kDebugMode && status != null && (status < 200 || status >= 300)) {
      debugPrint('[omni_mdm] presence heartbeat HTTP $status');
    }
  }

  Future<Result<void>> sendMetric(
    String metricKey,
    double value, {
    Map<String, dynamic>? payload,
  }) async {
    if (_session.instanceToken == null) return resultOk(null);

    Future<Result<void>> attempt() async {
      if (_config.mqttUrl != null) {
        final ok = await _mqtt.publish(
          _mqtt.topic('telemetry'),
          {
            'metric_key': metricKey,
            'metric_value': value,
            'payload': payload ?? {},
            'observed_at': DateTime.now().toUtc().toIso8601String(),
          },
          qos: MqttQos.atLeastOnce,
        );
        if (ok) return resultOk(null);
        if (kDebugMode) {
          debugPrint('[omni_mdm] mqtt telemetry failed, fallback HTTP');
        }
      }
      return _sendHttp(metricKey, value, payload: payload);
    }

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

  Future<Result<void>> _sendHttp(
    String metricKey,
    double value, {
    Map<String, dynamic>? payload,
  }) async {
    final token = _session.instanceToken!;
    try {
      final uri = Uri.parse('${_config.endpoint}/v1/ingest/telemetry');
      final client = HttpClient();
      try {
        final req = await client.postUrl(uri);
        req.headers.set('Content-Type', 'application/json');
        _config.applyTunnelHeaders(req);
        req.headers.set('Authorization', 'Bearer $token');
        req.add(utf8.encode(jsonEncode({
          'metric_key': metricKey,
          'metric_value': value,
          'payload': payload ?? {},
          'observed_at': DateTime.now().toUtc().toIso8601String(),
        })));
        final res = await req.close();
        if (res.statusCode >= 200 && res.statusCode < 300) {
          return resultOk(null);
        }
        return resultFail(AppFailure(
          code: 'telemetry_http_${res.statusCode}',
          message: 'telemetry failed',
        ));
      } finally {
        client.close(force: true);
      }
    } catch (e) {
      if (kDebugMode) debugPrint('[omni_mdm] telemetry failed: $e');
      return resultFail(AppFailure(code: 'telemetry_network', message: e.toString()));
    }
  }
}
