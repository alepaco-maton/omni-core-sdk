/// Sesión en memoria de la instancia enrolada.
class OmniSession {
  String? instanceId;
  String? businessId;
  String? instanceToken;
  String? hardwareFingerprint;
  String? hardwareRole;
  DateTime? tokenExpiresAt;

  bool get isEnrolled => instanceToken != null && instanceId != null;

  /// Renovar un poco antes del vencimiento real (margen 5 min o 10% del TTL).
  bool get needsTokenRefresh {
    final exp = tokenExpiresAt;
    if (instanceToken == null) return true;
    if (exp == null) return false; // legacy sin expiry: se refresca en init / 401
    final now = DateTime.now().toUtc();
    final skew = const Duration(minutes: 5);
    return !now.isBefore(exp.subtract(skew));
  }
}
