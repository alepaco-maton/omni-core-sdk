import 'package:flutter/services.dart';
import 'package:omni_mdm_core/omni_mdm_core.dart';

import '../mdm_capability.dart';

/// Health-check MQTT round-trip (latencia local de ejecución).
class PingCapability extends MdmCapability {
  const PingCapability();

  @override
  String get key => 'PING';

  @override
  bool get builtin => true;

  @override
  String get description => 'Health-check: confirma que el dispositivo recibe comandos MQTT';

  @override
  int get timeoutSeconds => 10;

  @override
  Map<String, dynamic> get resultSchema => const {
        'type': 'object',
        'properties': {
          'ok': {'type': 'boolean'},
          'round_trip_ms': {'type': 'integer'},
        },
      };

  @override
  Future<Result<Map<String, dynamic>>> execute(Map<String, dynamic> params) async {
    final started = DateTime.now();
    // Touch MethodChannel to prove native bridge is alive.
    var channelOk = false;
    try {
      await const MethodChannel('omni_mdm').invokeMethod<String>('getHardwareFingerprint');
      channelOk = true;
    } catch (_) {
      channelOk = false;
    }
    return resultOk({
      'ok': true,
      'channel_ok': channelOk,
      'round_trip_ms': DateTime.now().difference(started).inMilliseconds,
      'observed_at': DateTime.now().toUtc().toIso8601String(),
    });
  }
}
