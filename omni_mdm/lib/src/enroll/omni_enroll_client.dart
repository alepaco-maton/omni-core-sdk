import 'dart:convert'; 
import 'package:flutter/foundation.dart';
import 'package:omni_mdm_core/omni_mdm_core.dart';
import '../config/omni_mdm_config.dart';

class OmniEnrollResult {
  const OmniEnrollResult({
    required this.instanceId,
    required this.businessId,
    required this.instanceToken,
    required this.hardwareRole,
    this.tokenExpiresAt,
    this.reusedInstance = false,
  });

  final String instanceId;
  final String businessId;
  final String instanceToken;
  final String hardwareRole;
  final DateTime? tokenExpiresAt;
  final bool reusedInstance;
}

class OmniEnrollClient {
  OmniEnrollClient(this._config);

  final OmniMdmConfig _config;

  static String maskAppKey(String key) {
    final t = key.trim();
    if (t.length <= 12) return '***';
    return '${t.substring(0, 10)}…${t.substring(t.length - 4)}';
  }

  Future<Result<OmniEnrollResult>> enroll({
    required String hardwareFingerprint,
    String? appVersion,
    String? enrollmentToken,
  }) async {
    final endpoint = _config.endpoint.trim();
    final appKey = _config.appKey.trim();
    final uri = Uri.parse('$endpoint/v1/enroll');
    final hasTunnelToken =
        _config.tunnelAccessToken != null && _config.tunnelAccessToken!.trim().isNotEmpty;

    if (kDebugMode) {
      debugPrint(
        '[omni_mdm] enroll → POST $uri '
        'appKey=${maskAppKey(appKey)} '
        'hw=${hardwareFingerprint.length > 8 ? '${hardwareFingerprint.substring(0, 8)}…' : hardwareFingerprint} '
        'tunnelToken=${hasTunnelToken ? "yes" : "no"}',
      );
      if (endpoint.contains('devtunnels.ms') && !hasTunnelToken) {
        debugPrint(
          '[omni_mdm] WARN: Dev Tunnel sin X-Tunnel-Authorization. '
          'Si es privado → 401. Opciones: (1) allow-anonymous '
          'MDM/scripts/start-mdm-public-tunnel.ps1  '
          '(2) pegar token de `devtunnel token <id> --scopes connect` en Configuración.',
        );
      }
      if (OmniMdmConfig.isNgrokEndpoint(endpoint)) {
        debugPrint(
          '[omni_mdm] ngrok endpoint detectado — se envía ngrok-skip-browser-warning.',
        );
      }
    }

    try {
      final client = OmniMdmConfig.createHttpClient();
      try {
        final req = await client.postUrl(uri);
        req.headers.set('Content-Type', 'application/json');
        _config.applyTunnelHeaders(req);
        req.headers.set('X-Omni-App-Key', appKey);
        final secret = _config.appSecret?.trim();
        if (secret != null && secret.isNotEmpty) {
          req.headers.set('X-Omni-App-Secret', secret);
        }
        final token = enrollmentToken ?? await _config.enrollmentTokenProvider?.call();
        final payload = {
          'app_key': appKey,
          if (secret != null && secret.isNotEmpty) 'app_secret': secret,
          'hardware_fingerprint': hardwareFingerprint,
          'platform': 'android',
          'app_version': appVersion,
          'sdk_version': '0.1.0-m1',
          if (token != null) 'enrollment_token': token,
        };
        req.add(utf8.encode(jsonEncode(payload)));
        final res = await req.close();
        final body = await res.transform(utf8.decoder).join();
        final contentType = res.headers.value('content-type') ?? '';

        if (kDebugMode) {
          debugPrint(
            '[omni_mdm] enroll ← HTTP ${res.statusCode} '
            'content-type=$contentType bodyLen=${body.length}',
          );
          final snip = body.length > 400 ? '${body.substring(0, 400)}…' : body;
          debugPrint(
            snip.trim().isEmpty
                ? '[omni_mdm] enroll body: <vacío>'
                : '[omni_mdm] enroll body: $snip',
          );
        }

        if (res.statusCode >= 200 && res.statusCode < 300) {
          final json = jsonDecode(body) as Map<String, dynamic>;
          final expRaw = json['token_expires_at'] as String?;
          if (kDebugMode) {
            debugPrint(
              '[omni_mdm] enroll OK instance=${json['instance_id']} '
              'reused=${json['reused_instance']} exp=$expRaw',
            );
          }
          return resultOk(OmniEnrollResult(
            instanceId: json['instance_id'] as String,
            businessId: json['business_id'] as String,
            instanceToken: json['instance_token'] as String,
            hardwareRole: json['hardware_role'] as String? ?? 'guest',
            tokenExpiresAt: expRaw != null ? DateTime.tryParse(expRaw)?.toUtc() : null,
            reusedInstance: json['reused_instance'] == true,
          ));
        }

        final diagnosed = _diagnoseFailure(
          statusCode: res.statusCode,
          body: body,
          contentType: contentType,
          endpoint: endpoint,
          hasTunnelToken: hasTunnelToken,
        );
        if (kDebugMode) debugPrint('[omni_mdm] enroll FAIL: $diagnosed');
        return resultFail(AppFailure(
          code: 'enroll_http_${res.statusCode}',
          message: diagnosed,
        ));
      } finally {
        client.close(force: true);
      }
    } catch (e) {
      if (kDebugMode) debugPrint('[omni_mdm] enroll network error: $e');
      return resultFail(AppFailure(
        code: 'enroll_network',
        message: _formatNetworkError(e, endpoint),
      ));
    }
  }

  String _formatNetworkError(Object e, String endpoint) {
    final detail = e.toString();
    if (detail.contains('HandshakeException')) {
      if (OmniMdmConfig.isNgrokEndpoint(endpoint)) {
        return 'TLS handshake falló contra ngrok. Verifique: (1) `ngrok http 19080` activo en el PC, '
            '(2) la URL https://….ngrok-free.dev coincide con la consola ngrok, '
            '(3) el dispositivo tiene internet. Detalle: $detail';
      }
      return 'TLS handshake falló. ¿Endpoint accesible desde el dispositivo? $detail';
    }
    return detail;
  }

  String _diagnoseFailure({
    required int statusCode,
    required String body,
    required String contentType,
    required String endpoint,
    required bool hasTunnelToken,
  }) {
    final trimmed = body.trim();
    final looksHtml = contentType.contains('text/html') ||
        trimmed.startsWith('<!DOCTYPE') ||
        trimmed.toLowerCase().contains('html-auth') ||
        trimmed.toLowerCase().contains('github');

    if (statusCode == 401 &&
        (trimmed.isEmpty || looksHtml || endpoint.contains('devtunnels.ms'))) {
      if (hasTunnelToken) {
        return 'tunnel_token_rejected: X-Tunnel-Authorization enviado pero el '
            'gateway sigue en 401. Regenere token '
            '(`devtunnel token 462m7vmj --scopes connect`) o haga el tunnel anónimo.';
      }
      return 'tunnel_private_unauthorized: el navegador ve /v1/health porque tiene '
          'sesión GitHub; la app NO. Solución A (recomendada): '
          'MDM/scripts/start-mdm-public-tunnel.ps1 (allow-anonymous). '
          'Solución B: Configuración → Tunnel token = salida de '
          '`devtunnel token <id> --scopes connect`.';
    }

    if (trimmed.isEmpty) {
      return 'HTTP $statusCode sin cuerpo. Verifique endpoint API :19080.';
    }

    try {
      final json = jsonDecode(trimmed);
      if (json is Map) {
        final code = json['code']?.toString() ?? json['error']?.toString();
        final message = json['message']?.toString() ?? json['error']?.toString();
        if (code == 'invalid_app_key' || message == 'invalid_app_key') {
          return 'invalid_app_key: cree la app en consola :19081 y copie el key.';
        }
        return '${code ?? 'enroll_error'}: ${message ?? trimmed}';
      }
    } catch (_) {}

    if (looksHtml) {
      return 'non_api_response: HTML (login tunnel), no Omni API.';
    }

    final snip = trimmed.length > 280 ? '${trimmed.substring(0, 280)}…' : trimmed;
    return snip;
  }
}
