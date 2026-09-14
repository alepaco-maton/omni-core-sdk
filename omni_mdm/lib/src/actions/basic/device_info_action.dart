import 'package:omni_mdm_core/omni_mdm_core.dart';

import '../../device/omni_device_identity.dart';
import '../omni_remote_action.dart';

/// Acción básica: información del dispositivo y de la app anfitriona.
class DeviceInfoAction extends OmniBasicAction {
  const DeviceInfoAction();

  @override
  String get actionKey => 'device_info';

  @override
  Future<Result<Map<String, dynamic>>> execute(Map<String, dynamic> params) async {
    final info = await OmniDeviceIdentity.collectDeviceInfo();
    if (info == null) {
      return resultFail(const AppFailure(code: 'device_info_unavailable', message: 'No se pudo leer el dispositivo'));
    }
    return resultOk(info);
  }
}
