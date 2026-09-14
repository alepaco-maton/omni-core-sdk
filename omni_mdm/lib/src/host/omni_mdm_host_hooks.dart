/// Hooks opcionales que la app anfitriona implementa para capacidades MDM.
typedef OmniHostHook = Future<Map<String, dynamic>> Function(Map<String, dynamic> params);

abstract final class OmniMdmHostHooks {
  static OmniHostHook? onReloadConfig;
  static OmniHostHook? onLockAppUi;
  static OmniHostHook? onUnlockAppUi;
}
