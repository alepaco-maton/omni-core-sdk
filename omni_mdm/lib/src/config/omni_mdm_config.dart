import 'dart:io';

/// Configuración mínima de integración.
class OmniMdmConfig {
  const OmniMdmConfig({
    required this.appKey,
    required this.endpoint,
    this.appSecret,
    this.mqttUrl,
    this.syncOnly = false,
    this.syncIntervalSec = 300,
    this.tunnelAccessToken,
    this.enrollmentTokenProvider,
  });

  final String appKey;
  final String endpoint;
  final String? appSecret;

  /// URL MQTT opcional (ej. `mqtt://10.0.2.2:11883`). Si se define, la telemetría
  /// se publica en `omni/{businessId}/{instanceId}/telemetry`.
  final String? mqttUrl;

  /// Solo enroll + table-sync HTTP (sin MQTT, comandos, telemetría ni poll de acciones).
  final bool syncOnly;

  /// Intervalo de sync local en segundos (60–3600). El servidor puede sobreescribir vía settings.
  final int syncIntervalSec;

  /// Token Dev Tunnel (`devtunnel token <id> --scopes connect`).
  /// Se envía como `X-Tunnel-Authorization: tunnel <token>` para tunnels privados.
  /// Alternativa: tunnel con `--allow-anonymous` (no requiere token).
  final String? tunnelAccessToken;

  final Future<String?> Function()? enrollmentTokenProvider;

  /// Cliente HTTP con timeout estándar para requests MDM.
  static HttpClient createHttpClient() {
    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 30);
    return client;
  }

  static bool isNgrokEndpoint(String endpoint) {
    final e = endpoint.trim().toLowerCase();
    return e.contains('ngrok-free.app') ||
        e.contains('ngrok-free.dev') ||
        e.contains('.ngrok.io') ||
        e.contains('.ngrok.app');
  }

  /// Aplica headers de proxy/tunnel (Dev Tunnel, ngrok) a requests HTTP del SDK.
  void applyTunnelHeaders(HttpClientRequest req) {
    final token = tunnelAccessToken?.trim();
    if (token != null && token.isNotEmpty) {
      final value = token.toLowerCase().startsWith('tunnel ')
          ? token
          : 'tunnel $token';
      req.headers.set('X-Tunnel-Authorization', value);
    }
    // Dev Tunnel: evita página anti-phishing HTML.
    req.headers.set('X-Tunnel-Skip-AntiPhishing-Page', 'true');
    // ngrok free: sin este header algunos clientes fallan TLS o reciben HTML.
    if (isNgrokEndpoint(endpoint)) {
      req.headers.set('ngrok-skip-browser-warning', '69420');
      req.headers.set('User-Agent', 'BoA-OmniMDM/1.0');
    }
    req.headers.set('Accept', 'application/json');
  }

  Map<String, String> extraHttpHeaders() {
    final out = <String, String>{
      'X-Tunnel-Skip-AntiPhishing-Page': 'true',
      'Accept': 'application/json',
    };
    final token = tunnelAccessToken?.trim();
    if (token != null && token.isNotEmpty) {
      out['X-Tunnel-Authorization'] = token.toLowerCase().startsWith('tunnel ')
          ? token
          : 'tunnel $token';
    }
    if (isNgrokEndpoint(endpoint)) {
      out['ngrok-skip-browser-warning'] = '69420';
      out['User-Agent'] = 'BoA-OmniMDM/1.0';
    }
    return out;
  }
}
