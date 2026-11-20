import 'package:flutter/services.dart';
import 'package:omni_mdm_core/omni_mdm_core.dart';

import '../mdm_capability.dart';

/// Captura in-app (PixelCopy) vía canal nativo. No es screenshot de dispositivo.
class CaptureAppUiCapability extends MdmCapability {
  const CaptureAppUiCapability();

  static const _channel = MethodChannel('omni_mdm');

  @override
  String get key => 'CAPTURE_APP_UI';

  @override
  bool get builtin => true;

  @override
  String get description =>
      'Captura la UI de la Activity anfitriona (plugin). Requiere app en foreground.';

  @override
  int get timeoutSeconds => 20;

  @override
  Map<String, dynamic> get parameterSchema => const {
        'type': 'object',
        'properties': {
          'quality': {'type': 'integer'},
          'max_edge': {'type': 'integer'},
        },
      };

  @override
  Future<Result<Map<String, dynamic>>> execute(Map<String, dynamic> params) async {
    try {
      final raw = await _channel.invokeMethod<dynamic>('captureAppUi', {
        'quality': params['quality'] ?? 70,
        'max_edge': params['max_edge'] ?? 1280,
        if (params['command_id'] != null) 'command_id': params['command_id'],
      });
      if (raw is! Map) {
        return resultFail(const AppFailure(
          code: 'capture_invalid_result',
          message: 'Respuesta nativa inválida',
        ));
      }
      final map = Map<String, dynamic>.from(raw);
      map['transport'] = map['transport'] ?? 'mqtt';
      if (map['ok'] == true) return resultOk(map);
      return resultFail(AppFailure(
        code: map['error']?.toString() ?? 'capture_failed',
        message: map['error']?.toString() ?? 'Captura fallida',
      ));
    } on PlatformException catch (e) {
      return resultFail(AppFailure(
        code: e.code,
        message: e.message ?? 'capture_platform_error',
      ));
    } catch (e) {
      return resultFail(AppFailure(
        code: 'capture_failed',
        message: e.toString(),
      ));
    }
  }
}
