/// Evento de bitácora enviado a Omni MDM (espejo del AuditEvent de la app cliente).
class OmniAuditEvent {
  const OmniAuditEvent({
    required this.clientEventId,
    required this.deviceId,
    required this.observedAt,
    required this.eventType,
    required this.eventAction,
    this.screenName,
    this.endpoint,
    this.userName,
    this.ipAddress,
    this.metadata,
    this.jsonRequest,
    this.jsonResponse,
  });

  final String clientEventId;
  final String deviceId;
  final DateTime observedAt;
  final String eventType;
  final String eventAction;
  final String? screenName;
  final String? endpoint;
  final String? userName;
  final String? ipAddress;
  final Map<String, dynamic>? metadata;
  final String? jsonRequest;
  final String? jsonResponse;

  Map<String, dynamic> toJson() => {
        'client_event_id': clientEventId,
        'device_id': deviceId,
        'observed_at': observedAt.toUtc().toIso8601String(),
        'event_type': eventType,
        'event_action': eventAction,
        if (screenName != null) 'screen_name': screenName,
        if (endpoint != null) 'endpoint': endpoint,
        if (userName != null) 'user_name': userName,
        if (ipAddress != null) 'ip_address': ipAddress,
        if (metadata != null) 'metadata': metadata,
        if (jsonRequest != null) 'json_request': jsonRequest,
        if (jsonResponse != null) 'json_response': jsonResponse,
      };
}
