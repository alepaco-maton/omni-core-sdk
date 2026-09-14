import 'package:plugin_platform_interface/plugin_platform_interface.dart';

abstract class OmniMdmPlatform extends PlatformInterface {
  OmniMdmPlatform() : super(token: _token);

  static final Object _token = Object();
  static OmniMdmPlatform _instance = _DefaultOmniMdmPlatform();

  static OmniMdmPlatform get instance => _instance;

  static set instance(OmniMdmPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  Future<String?> getHardwareFingerprint();
}

class _DefaultOmniMdmPlatform extends OmniMdmPlatform {
  @override
  Future<String?> getHardwareFingerprint() async => null;
}
