import '../errors/app_failure.dart';

/// Resultado tipado: éxito con valor o fallo con [AppFailure].
sealed class Result<T> {
  const Result();

  bool get isOk => this is Ok<T>;
  bool get isFail => this is Fail<T>;

  R when<R>({
    required R Function(T value) ok,
    required R Function(AppFailure failure) fail,
  }) {
    return switch (this) {
      Ok<T>(:final value) => ok(value),
      Fail<T>(:final failure) => fail(failure),
    };
  }
}

final class Ok<T> extends Result<T> {
  const Ok(this.value);
  final T value;
}

final class Fail<T> extends Result<T> {
  const Fail(this.failure);
  final AppFailure failure;
}

Result<T> resultOk<T>(T value) => Ok(value);

Result<T> resultFail<T>(AppFailure failure) => Fail(failure);
