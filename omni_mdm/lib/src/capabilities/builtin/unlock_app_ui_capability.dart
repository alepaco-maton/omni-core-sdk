import 'package:omni_mdm_core/omni_mdm_core.dart';

import '../../host/omni_mdm_host_hooks.dart';
import '../mdm_capability.dart';

/// Desbloquea la UI de la app anfitriona.
class UnlockAppUiCapability extends MdmCapability {
  const UnlockAppUiCapability();

  @override
  String get key => 'UNLOCK_APP_UI';

  @override
  bool get builtin => true;

  @override
  String get description => 'Restaura interacción con la UI de la app anfitriona';

  @override
  Future<Result<Map<String, dynamic>>> execute(Map<String, dynamic> params) async {
    final hook = OmniMdmHostHooks.onUnlockAppUi;
    if (hook == null) {
      return resultOk({
        'locked': false,
        'reason': 'host_hook_not_configured',
      });
    }
    try {
      final result = await hook(params);
      return resultOk({
        'locked': false,
        ...result,
        'observed_at': DateTime.now().toUtc().toIso8601String(),
      });
    } catch (e) {
      return resultFail(AppFailure(code: 'unlock_app_ui_failed', message: e.toString()));
    }
  }
}
