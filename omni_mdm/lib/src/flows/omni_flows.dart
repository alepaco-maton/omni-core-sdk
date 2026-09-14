import 'package:uuid/uuid.dart';

import '../flows/omni_flow_client.dart';

class OmniFlowInstanceHandle {
  OmniFlowInstanceHandle({
    required this.flowInstanceId,
    required this.flowKey,
    this.correlationId,
  });

  final String flowInstanceId;
  final String flowKey;
  final String? correlationId;
  int _sequence = 0;

  int nextSequence() => ++_sequence;

  OmniFlowEvent stepEvent({
    required String stepKey,
    required String eventType,
    String state = 'in_progress',
    Map<String, dynamic> metadata = const {},
  }) {
    return OmniFlowEvent(
      flowInstanceId: flowInstanceId,
      flowKey: flowKey,
      stepKey: stepKey,
      eventType: eventType,
      sequence: nextSequence(),
      correlationId: correlationId,
      state: state,
      metadata: metadata,
    );
  }
}

class OmniFlows {
  OmniFlows(this._client);

  final OmniFlowClient _client;
  final _uuid = const Uuid();

  OmniFlowInstanceHandle start(String flowKey, {String? correlationId}) {
    return OmniFlowInstanceHandle(
      flowInstanceId: _uuid.v4(),
      flowKey: flowKey,
      correlationId: correlationId,
    );
  }

  Future<void> emit(OmniFlowEvent event) async {
    await _client.sendEvents([event]);
  }

  Future<void> emitAll(List<OmniFlowEvent> events) async {
    await _client.sendEvents(events);
  }
}
