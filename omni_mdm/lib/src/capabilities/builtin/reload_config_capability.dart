import 'package:omni_mdm_core/omni_mdm_core.dart';

import '../../host/omni_mdm_host_hooks.dart';
import '../mdm_capability.dart';

/// Recarga configuración runtime de la app anfitriona (endpoint, MQTT, etc.).
class ReloadConfigCapability extends MdmCapability {
  const ReloadConfigCapability();

  @override
  String get key => 'RELOAD_CONFIG';

  @override
  bool get builtin => true;

  @override
  String get description =>
      'Recarga configuración local de la app y reinicializa servicios MDM';

  @override
  Future<Result<Map<String, dynamic>>> execute(Map<String, dynamic> params) async {
    final hook = OmniMdmHostHooks.onReloadConfig;
    if (hook == null) {
      return resultOk({
        'reloaded': false,
        'reason': 'host_hook_not_configured',
        'observed_at': DateTime.now().toUtc().toIso8601String(),
      });
    }
    try {
      final result = await hook(params);
      return resultOk({
        ...result,
        'observed_at': DateTime.now().toUtc().toIso8601String(),
      });
    } catch (e) {
      return resultFail(AppFailure(code: 'reload_config_failed', message: e.toString()));
    }
  }
}
