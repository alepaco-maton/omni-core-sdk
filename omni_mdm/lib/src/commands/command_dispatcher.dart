import 'dart:convert';

import 'package:flutter/services.dart';

import '../mqtt/omni_mqtt_client.dart';
import '../capabilities/capability_registry.dart';
import 'command_hooks.dart';

/// Recibe comandos MQTT, ejecuta capacidades y publica ACK/resultado.
/// Idempotencia compartida con poll HTTP nativo vía MethodChannel.
class CommandDispatcher {
  CommandDispatcher(this._mqtt, this._registry);

  final OmniMqttClient _mqtt;
  final CapabilityRegistry _registry;
  final Set<String> _executed = {};
  static const _channel = MethodChannel('omni_mdm');

  Future<void> start() async {
    if (!await _mqtt.ensureConnected()) return;
    final cmdTopic = _mqtt.topic('cmd/request');
    final shadowTopic = _mqtt.topic('shadow/desired');
    _mqtt.subscribe(cmdTopic, (_, payload) => _onCommand(payload));
    _mqtt.subscribe(shadowTopic, (_, payload) => _onShadow(payload));
  }

  Future<void> stop() async {
    _executed.clear();
  }

  Future<void> _onCommand(List<int> payload) async {
    final body = _decode(payload);
    if (body == null) return;
    await _handleCommand(body);
  }

  Future<void> _onShadow(List<int> payload) async {
    final body = _decode(payload);
    if (body == null) return;
    final pending = body['pending_commands'];
    if (pending is! List) return;
    for (final item in pending) {
      if (item is Map<String, dynamic>) {
        await _handleCommand(item);
      } else if (item is Map) {
        await _handleCommand(Map<String, dynamic>.from(item));
      }
    }
  }

  Future<bool> _alreadyDone(String commandId) async {
    if (_executed.contains(commandId)) return true;
    try {
      final v = await _channel.invokeMethod<bool>('commandAlreadyDone', {
        'command_id': commandId,
      });
      return v == true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _markDone(String commandId, String capability) async {
    _executed.add(commandId);
    try {
      await _channel.invokeMethod<void>('markCommandExecuted', {
        'command_id': commandId,
        'command_key': capability,
        'transport': 'mqtt',
      });
    } catch (_) {}
  }

  Future<void> _handleCommand(Map<String, dynamic> body) async {
    final commandId = body['command_id']?.toString();
    final capability = (body['capability'] ?? body['command_key'])?.toString();
    if (commandId == null || capability == null) return;
    if (await _alreadyDone(commandId)) {
      await _publishResult(commandId, 'succeeded', result: {
        'idempotent': true,
        'transport': 'mqtt',
      });
      return;
    }

    await _publishResult(commandId, 'acked');
    await _publishResult(commandId, 'running');

    final params = body['params'] is Map
        ? Map<String, dynamic>.from(body['params'] as Map)
        : <String, dynamic>{};
    params['command_id'] = commandId;

    if (capability == 'PUBLISH_MANIFEST') {
      await publishManifest();
      await _markDone(commandId, capability);
      await _publishResult(commandId, 'succeeded', result: {
        'published': true,
        'transport': 'mqtt',
      });
      return;
    }

    final res = await _registry.execute(capability, params);
    if (res.isOk) {
      await _markDone(commandId, capability);
      final value = res.when(ok: (v) => v, fail: (_) => <String, dynamic>{});
      value['transport'] = value['transport'] ?? 'mqtt';
      await _publishResult(commandId, 'succeeded', result: value);
      final hook = onCommandSucceeded;
      if (hook != null) {
        try {
          await hook(capability, value);
        } catch (_) {}
      }
    } else {
      final failure = res.when(ok: (_) => null, fail: (f) => f);
      await _publishResult(commandId, 'failed', reason: failure?.code, error: {
        'code': failure?.code,
        'message': failure?.message,
      });
    }
  }

  Future<void> publishManifest({String? appVersion}) async {
    final manifest = _registry.toManifest(appVersion: appVersion);
    await _mqtt.publish(_mqtt.topic('manifest'), manifest);
  }

  Future<void> _publishResult(
    String commandId,
    String state, {
    Map<String, dynamic>? result,
    String? reason,
    Map<String, dynamic>? error,
  }) async {
    await _mqtt.publish(_mqtt.topic('cmd/result'), {
      'command_id': commandId,
      'state': state,
      'observed_at': DateTime.now().toUtc().toIso8601String(),
      if (result != null) 'result': result,
      if (reason != null) 'reason': reason,
      if (error != null) 'error': error,
    });
  }

  Map<String, dynamic>? _decode(List<int> payload) {
    try {
      final text = String.fromCharCodes(payload);
      final decoded = jsonDecode(text);
      if (decoded is Map<String, dynamic>) return decoded;
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    } catch (_) {}
    return null;
  }
}
