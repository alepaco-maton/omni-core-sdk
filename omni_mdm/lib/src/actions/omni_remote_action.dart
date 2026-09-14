import 'package:omni_mdm_core/omni_mdm_core.dart';

/// Acción remota lanzada desde el backoffice MDM hacia la app anfitriona.
abstract class OmniRemoteAction {
  const OmniRemoteAction();

  /// Clave estable, p. ej. `device_info` o `host_query`.
  String get actionKey;

  Future<Result<Map<String, dynamic>>> execute(Map<String, dynamic> params);
}

/// Acciones básicas del SDK (no requieren código de la app anfitriona).
abstract class OmniBasicAction extends OmniRemoteAction {
  const OmniBasicAction();
}

/// Acciones abstractas: el desarrollador de la app de terceros hereda e implementa.
abstract class OmniHostAction extends OmniRemoteAction {
  const OmniHostAction();
}
