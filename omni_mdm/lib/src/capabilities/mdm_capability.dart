import 'package:omni_mdm_core/omni_mdm_core.dart';

/// Contrato base para capacidades extensibles (E7).
abstract class MdmCapability {
  const MdmCapability();

  String get key;
  String get version => '1.0.0';
  String get kind => 'request';
  String get scope => 'app';
  bool get builtin => false;
  String get description => key;
  bool get requiresConsent => false;
  int get timeoutSeconds => 30;

  Map<String, dynamic> get parameterSchema => const {'type': 'object'};
  Map<String, dynamic> get resultSchema => const {'type': 'object'};

  Future<Result<Map<String, dynamic>>> execute(Map<String, dynamic> params);
}
