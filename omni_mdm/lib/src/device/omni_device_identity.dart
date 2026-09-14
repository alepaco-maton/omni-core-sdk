import 'package:flutter/services.dart';

class OmniDeviceIdentity {
  static const _channel = MethodChannel('omni_mdm');

  static Future<String?> hardwareFingerprint() async {
    try {
      final value = await _channel.invokeMethod<String>('getHardwareFingerprint');
      return value;
    } catch (_) {
      return null;
    }
  }

  /// ID estable persistido en el dispositivo (independiente del usuario de la app).
  static Future<String?> stableDeviceId() async {
    try {
      final value = await _channel.invokeMethod<String>('getStableDeviceId');
      return value;
    } catch (_) {
      return hardwareFingerprint();
    }
  }

  static Future<Map<String, dynamic>?> collectDeviceInfo() async {
    try {
      final raw = await _channel.invokeMethod<dynamic>('getDeviceInfo');
      if (raw is Map) {
        return Map<String, dynamic>.from(raw);
      }
    } catch (_) {}
    return null;
  }
}
