import 'package:omni_mdm_core/omni_mdm_core.dart';

import 'omni_remote_action.dart';

/// Punto de extensión para consultas propias de la app (SQLite, flujos, etc.).
///
/// El desarrollador de la app anfitriona hereda e implementa [runHostQuery].
/// Ejemplo:
/// ```dart
/// class BoaSqliteQuery extends OmniHostQueryAction {
///   @override
///   Future<Map<String, dynamic>> runHostQuery(Map<String, dynamic> params) async {
///     final rows = await myDb.rawQuery(params['sql'] as String);
///     return {'rows': rows};
///   }
/// }
/// OmniMdm.registerHostAction(BoaSqliteQuery());
/// ```
abstract class OmniHostQueryAction extends OmniHostAction {
  const OmniHostQueryAction();

  @override
  String get actionKey => 'host_query';

  Future<Map<String, dynamic>> runHostQuery(Map<String, dynamic> params);

  @override
  Future<Result<Map<String, dynamic>>> execute(Map<String, dynamic> params) async {
    try {
      final data = await runHostQuery(params);
      return resultOk(data);
    } catch (e) {
      return resultFail(AppFailure(code: 'host_query_failed', message: e.toString()));
    }
  }
}
