import 'package:omni_mdm_core/omni_mdm_core.dart';

import '../../host/omni_mdm_host_hooks.dart';
import '../mdm_capability.dart';

/// Bloquea la UI de la app anfitriona (overlay modal).
class LockAppUiCapability extends MdmCapability {
  const LockAppUiCapability();

  @override
  String get key => 'LOCK_APP_UI';

  @override
  bool get builtin => true;

  @override
  String get description => 'Bloquea interacción con la UI de la app anfitriona';

  @override
  Map<String, dynamic> get parameterSchema => const {
        'type': 'object',
        'properties': {
          'message': {'type': 'string'},
        },
      };

  @override
  Future<Result<Map<String, dynamic>>> execute(Map<String, dynamic> params) async {
    final hook = OmniMdmHostHooks.onLockAppUi;
    if (hook == null) {
      return resultOk({
        'locked': false,
        'reason': 'host_hook_not_configured',
      });
    }
    try {
      final result = await hook(params);
      return resultOk({
        'locked': true,
        ...result,
        'observed_at': DateTime.now().toUtc().toIso8601String(),
      });
    } catch (e) {
      return resultFail(AppFailure(code: 'lock_app_ui_failed', message: e.toString()));
    }
  }
}
