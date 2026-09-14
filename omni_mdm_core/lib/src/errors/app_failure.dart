/// Fallo de dominio estable del SDK.
class AppFailure {
  const AppFailure({
    required this.code,
    required this.message,
  });

  final String code;
  final String message;

  @override
  String toString() => 'AppFailure($code: $message)';
}
