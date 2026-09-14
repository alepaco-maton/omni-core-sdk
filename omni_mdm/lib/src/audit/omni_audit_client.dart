import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:omni_mdm_core/omni_mdm_core.dart';

import '../auth/omni_auth_refresh.dart';
import '../config/omni_mdm_config.dart';
import '../session/omni_session.dart';
import 'omni_audit_event.dart';

/// Cliente HTTP mínimo para dual-write de bitácora.
class OmniAuditClient {
  OmniAuditClient(
    this._config,
    this._session, {
    OmniAuthRefresh? onUnauthorized,
  }) : _onUnauthorized = onUnauthorized;

  final OmniMdmConfig _config;
  final OmniSession _session;
  final OmniAuthRefresh? _onUnauthorized;

  Future<Result<void>> sendEvents(List<OmniAuditEvent> events) async {
    if (events.isEmpty) return resultOk(null);

    Future<Result<void>> attempt() => _sendOnce(events);

    final first = await attempt();
    if (first is Ok<void>) return first;

    final failure = (first as Fail<void>).failure;
    final refresh = _onUnauthorized;
    if (!isUnauthorizedFailure(failure) || refresh == null) {
      return first;
    }

    final refreshed = await refresh();
    if (!refreshed) return first;
    return attempt();
  }

  Future<Result<void>> _sendOnce(List<OmniAuditEvent> events) async {
    try {
      final uri = Uri.parse('${_config.endpoint}/v1/ingest/audit-events');
      final client = HttpClient();
      try {
        final req = await client.postUrl(uri);
        req.headers.set('Content-Type', 'application/json');
        _config.applyTunnelHeaders(req);
        req.headers.set('X-Omni-App-Key', _config.appKey);
        final secret = _config.appSecret?.trim();
        if (secret != null && secret.isNotEmpty) {
          req.headers.set('X-Omni-App-Secret', secret);
        }
        req.headers.set('X-Omni-Device-Id', events.first.deviceId);
        final token = _session.instanceToken;
        if (token != null) {
          req.headers.set('Authorization', 'Bearer $token');
        }
        req.add(utf8.encode(jsonEncode({
          'events': events.map((e) => e.toJson()).toList(),
        })));
        final res = await req.close();
        final body = await res.transform(utf8.decoder).join();
        if (res.statusCode >= 200 && res.statusCode < 300) {
          return resultOk(null);
        }
        return resultFail(AppFailure(
          code: 'ingest_http_${res.statusCode}',
          message: body.isNotEmpty
              ? body
              : 'Omni MDM ingest failed with ${res.statusCode}',
        ));
      } finally {
        client.close(force: true);
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[omni_mdm] audit ingest failed silently: $e');
      }
      return resultFail(
        AppFailure(code: 'ingest_network', message: e.toString()),
      );
    }
  }
}
