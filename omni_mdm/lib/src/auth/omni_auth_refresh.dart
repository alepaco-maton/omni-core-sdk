import 'package:omni_mdm_core/omni_mdm_core.dart';

/// Callback para renovar credenciales de instancia ante 401.
typedef OmniAuthRefresh = Future<bool> Function();

bool isUnauthorizedFailure(AppFailure failure) {
  final code = failure.code.toLowerCase();
  final message = failure.message.toLowerCase();
  return code.contains('401') ||
      code.contains('403') ||
      code.contains('unauthorized') ||
      code.contains('invalid_instance') ||
      code.contains('instance_not_enrolled') ||
      code.contains('missing bearer') ||
      message.contains('invalid instance token') ||
      message.contains('instance_not_enrolled') ||
      message.contains('device not enrolled') ||
      message.contains('invalid_app_key') ||
      message.contains('app_key_required') ||
      message.contains('missing bearer');
}

/// Ejecuta [action]; si falla por auth, refresca una vez y reintenta.
Future<Result<T>> withAuthRetry<T>(
  Future<Result<T>> Function() action, {
  required OmniAuthRefresh refresh,
}) async {
  final first = await action();
  if (first is Ok<T>) return first;
  final failure = (first as Fail<T>).failure;
  if (!isUnauthorizedFailure(failure)) return first;

  final refreshed = await refresh();
  if (!refreshed) return first;
  return action();
}
