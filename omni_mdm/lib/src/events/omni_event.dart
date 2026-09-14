/// Evento genérico del plugin. Cada empresa define sus propios `eventType` / `eventName`.
class OmniEvent {
  const OmniEvent({
    required this.eventType,
    required this.eventName,
    this.payload = const {},
    this.occurredAt,
    this.deviceId,
  });

  /// Familia abierta: `flow`, `crash`, `user_action`, `notification`,
  /// `app_open`, `summary`, `auth`, `custom`, u otra que defina la app.
  final String eventType;
  final String eventName;
  final Map<String, dynamic> payload;
  final DateTime? occurredAt;
  final String? deviceId;

  Map<String, dynamic> toJson(String resolvedDeviceId) => {
        'event_type': eventType,
        'event_name': eventName,
        'payload': payload,
        'occurred_at': (occurredAt ?? DateTime.now().toUtc()).toIso8601String(),
        'device_id': deviceId ?? resolvedDeviceId,
      };
}
