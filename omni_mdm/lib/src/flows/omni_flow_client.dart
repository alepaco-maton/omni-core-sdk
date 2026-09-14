import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:omni_mdm_core/omni_mdm_core.dart';

import '../config/omni_mdm_config.dart';
import '../session/omni_session.dart';

class OmniFlowEvent {
  const OmniFlowEvent({
    required this.flowInstanceId,
    required this.flowKey,
    required this.stepKey,
    required this.eventType,
    required this.sequence,
    this.correlationId,
    this.state = 'in_progress',
    this.observedAt,
    this.metadata = const {},
  });

  final String flowInstanceId;
  final String flowKey;
  final String stepKey;
  final String eventType;
  final int sequence;
  final String? correlationId;
  final String state;
  final DateTime? observedAt;
  final Map<String, dynamic> metadata;

  Map<String, dynamic> toJson() => {
        'flow_instance_id': flowInstanceId,
        'flow_key': flowKey,
        'step_key': stepKey,
        'event_type': eventType,
        'sequence': sequence,
        if (correlationId != null) 'correlation_id': correlationId,
        'state': state,
        'observed_at': (observedAt ?? DateTime.now().toUtc()).toIso8601String(),
        'metadata': metadata,
      };
}

class OmniFlowClient {
  OmniFlowClient(this._config, this._session);

  final OmniMdmConfig _config;
  final OmniSession _session;

  Future<Result<void>> sendEvents(List<OmniFlowEvent> events) async {
    final token = _session.instanceToken;
    if (token == null || events.isEmpty) return resultOk(null);
    try {
      final uri = Uri.parse('${_config.endpoint}/v1/ingest/flow-events');
      final client = HttpClient();
      try {
        final req = await client.postUrl(uri);
        req.headers.set('Content-Type', 'application/json');
        req.headers.set('Authorization', 'Bearer $token');
        req.add(utf8.encode(jsonEncode({
          'events': events.map((e) => e.toJson()).toList(),
        })));
        final res = await req.close();
        if (res.statusCode >= 200 && res.statusCode < 300) {
          return resultOk(null);
        }
        return resultFail(AppFailure(
          code: 'flow_http_${res.statusCode}',
          message: 'flow ingest failed',
        ));
      } finally {
        client.close(force: true);
      }
    } catch (e) {
      if (kDebugMode) debugPrint('[omni_mdm] flow ingest failed: $e');
      return resultFail(AppFailure(code: 'flow_network', message: e.toString()));
    }
  }
}
