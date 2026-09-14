import 'package:omni_mdm_core/omni_mdm_core.dart';

import 'builtin/device_info_capability.dart';
import 'builtin/lock_app_ui_capability.dart';
import 'builtin/ping_capability.dart';
import 'builtin/reload_config_capability.dart';
import 'builtin/unlock_app_ui_capability.dart';
import 'mdm_capability.dart';

/// Registro de capacidades del SDK (built-in + custom del host).
class CapabilityRegistry {
  CapabilityRegistry() {
    registerAll([
      const PingCapability(),
      const DeviceInfoCapability(),
      const ReloadConfigCapability(),
      const LockAppUiCapability(),
      const UnlockAppUiCapability(),
    ]);
  }

  final Map<String, MdmCapability> _byKey = {};

  void register(MdmCapability capability) => _byKey[capability.key] = capability;

  void registerAll(Iterable<MdmCapability> capabilities) {
    for (final c in capabilities) {
      register(c);
    }
  }

  MdmCapability? get(String key) => _byKey[key];

  bool supports(String key) => _byKey.containsKey(key);

  List<MdmCapability> get all => _byKey.values.toList();

  Map<String, dynamic> toManifest({String sdkVersion = '0.1.0-m2', String? appVersion}) {
    return {
      'sdk_version': sdkVersion,
      if (appVersion != null) 'app_version': appVersion,
      'published_at': DateTime.now().toUtc().toIso8601String(),
      'capabilities': all
          .map((c) => {
                'key': c.key,
                'version': c.version,
                'kind': c.kind,
                'scope': c.scope,
                'builtin': c.builtin,
                'description': c.description,
                'parameter_schema': c.parameterSchema,
                'result_schema': c.resultSchema,
                'requires_consent': c.requiresConsent,
                'timeout_seconds': c.timeoutSeconds,
              })
          .toList(),
    };
  }

  Future<Result<Map<String, dynamic>>> execute(String key, Map<String, dynamic> params) async {
    final cap = _byKey[key];
    if (cap == null) {
      return resultFail(AppFailure(
        code: 'capability_not_supported',
        message: 'Capability $key not registered',
      ));
    }
    return cap.execute(params);
  }
}
