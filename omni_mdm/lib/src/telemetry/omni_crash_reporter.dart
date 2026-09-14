import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../config/omni_mdm_config.dart';
import '../session/omni_session.dart';

class OmniCrashReporter {
  OmniCrashReporter(this._config, this._session);

  final OmniMdmConfig _config;
  final OmniSession _session;

  Future<void> reportFlutterError(FlutterErrorDetails details) async {
    await _send(
      message: details.exceptionAsString(),
      stackTrace: details.stack?.toString(),
      fingerprint: 'flutter:${details.exception.runtimeType}',
    );
  }

  Future<void> reportError(Object error, StackTrace stack) async {
    await _send(
      message: error.toString(),
      stackTrace: stack.toString(),
      fingerprint: 'dart:${error.runtimeType}',
    );
  }

  Future<void> _send({
    required String message,
    String? stackTrace,
    required String fingerprint,
  }) async {
    final token = _session.instanceToken;
    if (token == null) return;
    try {
      final uri = Uri.parse('${_config.endpoint}/v1/ingest/crashes');
      final client = HttpClient();
      try {
        final req = await client.postUrl(uri);
        req.headers.set('Content-Type', 'application/json');
        req.headers.set('Authorization', 'Bearer $token');
        req.add(utf8.encode(jsonEncode({
          'fingerprint': fingerprint,
          'message': message,
          'stack_trace': stackTrace,
          'metadata': {'library': 'flutter'},
        })));
        await req.close();
      } finally {
        client.close(force: true);
      }
    } catch (e) {
      if (kDebugMode) debugPrint('[omni_mdm] crash report failed: $e');
    }
  }
}
