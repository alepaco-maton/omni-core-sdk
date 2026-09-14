import 'dart:io';

import 'package:flutter/services.dart';
import 'package:omni_mdm_core/omni_mdm_core.dart';

import '../../device/omni_device_identity.dart';
import '../mdm_capability.dart';

/// Inventario completo del dispositivo bajo demanda (comando de consola).
class DeviceInfoCapability extends MdmCapability {
  const DeviceInfoCapability();

  static const _channel = MethodChannel('omni_mdm');

  @override
  String get key => 'DEVICE_INFO';

  @override
  bool get builtin => true;

  @override
  String get description =>
      'Inventario completo: fingerprint, modelo, OS, batería, almacenamiento, versión de app';

  @override
  Map<String, dynamic> get resultSchema => const {
        'type': 'object',
        'properties': {
          'hardware_fingerprint': {'type': 'string'},
          'platform': {'type': 'string'},
          'manufacturer': {'type': 'string'},
          'model': {'type': 'string'},
          'os_version': {'type': 'string'},
          'battery_level': {'type': 'integer'},
          'app_version': {'type': 'string'},
        },
      };

  @override
  Future<Result<Map<String, dynamic>>> execute(Map<String, dynamic> params) async {
    try {
      Map<String, dynamic>? native;
      try {
        final raw = await _channel.invokeMethod<dynamic>('getDeviceInfo');
        if (raw is Map) {
          native = Map<String, dynamic>.from(raw);
        }
      } catch (_) {
        native = null;
      }

      final fingerprint = native?['hardware_fingerprint']?.toString() ??
          await OmniDeviceIdentity.hardwareFingerprint();

      final payload = <String, dynamic>{
        'platform': Platform.operatingSystem,
        'os': Platform.operatingSystem,
        'os_version': Platform.operatingSystemVersion,
        'hardware_fingerprint': fingerprint,
        'dart_locale': Platform.localeName,
        'number_of_processors': Platform.numberOfProcessors,
        'observed_at': DateTime.now().toUtc().toIso8601String(),
        'source': native != null ? 'native' : 'dart_fallback',
      };

      if (native != null) {
        for (final e in native.entries) {
          if (e.value != null) payload[e.key] = e.value;
        }
      }

      return resultOk(payload);
    } catch (e) {
      return resultFail(AppFailure(code: 'device_info_failed', message: e.toString()));
    }
  }
}
