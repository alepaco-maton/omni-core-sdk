import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../config/omni_mdm_config.dart';
import '../session/omni_session.dart';
import 'omni_circuit_breaker.dart';
import 'omni_event.dart';
import 'omni_event_store.dart';

/// Sync silencioso en batch. Intervalo, cola y circuit breaker los define el backoffice.
class OmniEventSync {
  OmniEventSync(this._config, this._session, {OmniEventStore? store})
      : _store = store ?? OmniEventStore();

  final OmniMdmConfig _config;
  final OmniSession _session;
  final OmniEventStore _store;
  final OmniCircuitBreaker circuit = OmniCircuitBreaker();
  Timer? _timer;
  int _intervalSec = 300;
  int _batchMax = 100;
  int _queueMax = 500;
  bool _inFlight = false;

  int get intervalSec => _intervalSec;
  int get batchMax => _batchMax;
  int get queueMax => _queueMax;

  Future<void> start() async {
    await refreshSettings();
    _restartTimer();
    unawaited(flush());
  }

  void _restartTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(Duration(seconds: _intervalSec), (_) {
      unawaited(flush());
    });
  }

  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
  }

  Future<void> enqueue(OmniEvent event, String deviceId) {
    return _store.enqueue(event, deviceId, maxQueue: _queueMax);
  }

  Future<void> refreshSettings() async {
    if (!_session.isEnrolled || _session.businessId == null) return;
    if (!circuit.allowRequest()) return;
    final client = OmniMdmConfig.createHttpClient();
    client.connectionTimeout = Duration(milliseconds: circuit.probeTimeoutMs);
    try {
      final uri = Uri.parse('${_config.endpoint}/v1/sdk/settings');
      final req = await client.getUrl(uri);
      req.headers.set('Authorization', 'Bearer ${_session.instanceToken}');
      _config.applyTunnelHeaders(req);
      final resp = await req.close().timeout(Duration(milliseconds: circuit.probeTimeoutMs));
      final body = await resp.transform(utf8.decoder).join();
      if (resp.statusCode >= 200 && resp.statusCode < 300) {
        final json = jsonDecode(body);
        if (json is Map) {
          final map = Map<String, dynamic>.from(json);
          _intervalSec = (map['sync_interval_sec'] as num?)?.toInt() ?? 300;
          _batchMax = (map['batch_max'] as num?)?.toInt() ?? 100;
          _queueMax = (map['sdk_queue_max'] as num?)?.toInt() ?? 500;
          circuit.applySettings(map);
          circuit.onSuccess();
          _restartTimer();
        }
      } else {
        circuit.onFailure(HttpException('sdk_settings ${resp.statusCode}'));
      }
    } catch (e) {
      circuit.onFailure(e);
      if (kDebugMode) debugPrint('[omni_mdm] sdk settings: $e circuit=${circuit.state}');
    } finally {
      client.close();
    }
  }

  Future<void> flush() async {
    if (_inFlight || !_session.isEnrolled) return;
    if (!circuit.allowRequest()) {
      if (kDebugMode) {
        debugPrint('[omni_mdm] circuit ${circuit.state} · retry ${circuit.retryInSec()}s');
      }
      return;
    }
    _inFlight = true;
    try {
      final batch = await _store.take(_batchMax);
      if (batch.isEmpty) {
        unawaited(refreshSettings());
        return;
      }
      final client = OmniMdmConfig.createHttpClient();
      client.connectionTimeout = Duration(milliseconds: circuit.probeTimeoutMs);
      try {
        final uri = Uri.parse('${_config.endpoint}/v1/ingest/sdk-events');
        final req = await client.postUrl(uri);
        req.headers.set('Authorization', 'Bearer ${_session.instanceToken}');
        req.headers.contentType = ContentType.json;
        _config.applyTunnelHeaders(req);
        req.add(utf8.encode(jsonEncode({'items': batch})));
        final resp = await req.close().timeout(Duration(milliseconds: circuit.probeTimeoutMs + 4000));
        await resp.drain<void>();
        if (resp.statusCode < 200 || resp.statusCode >= 300) {
          await _store.prepend(batch);
          circuit.onFailure(HttpException('ingest ${resp.statusCode}'));
        } else {
          circuit.onSuccess();
        }
      } catch (e) {
        await _store.prepend(batch);
        circuit.onFailure(e);
      } finally {
        client.close();
      }
    } finally {
      _inFlight = false;
    }
  }
}
