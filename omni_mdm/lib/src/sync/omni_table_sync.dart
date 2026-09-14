import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../device/omni_device_identity.dart';
import 'omni_sync_channel.dart';

/// Puente Dart ↔ Kotlin para canales PUSH_ONLY / PULL_ONLY.
class OmniTableSync {
  OmniTableSync._();

  static const _channel = MethodChannel('omni_mdm');
  static OmniPushBatchHost? _host;
  static bool _handlerBound = false;

  static void bindHost(OmniPushBatchHost? host) {
    _host = host;
    if (_handlerBound) return;
    _handlerBound = true;
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'takePushBatch':
          final args = Map<String, dynamic>.from(call.arguments as Map);
          final channelId = args['channelId']?.toString() ?? '';
          final limit = (args['limit'] as num?)?.toInt() ?? 100;
          final host = _host;
          if (host == null) return {'events': <dynamic>[], 'ids': <String>[]};
          final events = await host.take(channelId, limit);
          final ids = events
              .map((e) => e['client_event_id']?.toString())
              .whereType<String>()
              .toList();
          return {'events': events, 'ids': ids};
        case 'ackPushBatch':
          final args = Map<String, dynamic>.from(call.arguments as Map);
          final channelId = args['channelId']?.toString() ?? '';
          final ids = (args['ids'] as List?)?.map((e) => e.toString()).toList() ??
              const <String>[];
          await _host?.ack(channelId, ids);
          return null;
        default:
          return null;
      }
    });
  }

  static Future<void> configure({
    required String endpoint,
    required String appKey,
    String? appSecret,
    String? token,
    required List<OmniSyncChannel> channels,
    Map<String, String> headers = const {},
    int? syncIntervalSec,
  }) async {
    try {
      final deviceId = await OmniDeviceIdentity.stableDeviceId() ?? 'unknown';
      await _channel.invokeMethod<void>('configureTableSync', {
        'endpoint': endpoint,
        'appKey': appKey,
        'appSecret': appSecret,
        'token': token,
        'deviceId': deviceId,
        'headers': headers,
        'channels': channels.map((c) => c.toNativeMap()).toList(),
        if (syncIntervalSec != null) 'syncIntervalSec': syncIntervalSec,
      });
    } catch (e) {
      if (kDebugMode) debugPrint('[omni_mdm] configureTableSync: $e');
    }
  }

  static Future<void> schedule() async {
    try {
      await _channel.invokeMethod<void>('scheduleTableSync');
    } catch (e) {
      if (kDebugMode) debugPrint('[omni_mdm] scheduleTableSync: $e');
    }
  }

  /// Sync inmediato + reprogramación del ciclo (resume / apertura).
  static Future<void> triggerNow() async {
    try {
      await _channel.invokeMethod<void>('triggerTableSync');
    } catch (e) {
      if (kDebugMode) debugPrint('[omni_mdm] triggerTableSync: $e');
    }
  }

  static Future<void> enqueuePluginEvent({
    required String id,
    required String createdAt,
    required String eventType,
    required String eventAction,
    String payloadJson = '{}',
  }) async {
    try {
      await _channel.invokeMethod<void>('enqueuePluginEvent', {
        'id': id,
        'created_at': createdAt,
        'event_type': eventType,
        'event_action': eventAction,
        'payload': payloadJson,
      });
    } catch (e) {
      if (kDebugMode) debugPrint('[omni_mdm] enqueuePluginEvent: $e');
    }
  }

  static Future<Map<String, dynamic>> runSynchronized({bool resetCircuit = false}) async {
    try {
      final raw = await _channel.invokeMethod<dynamic>('runSynchronized', {
        'resetCircuit': resetCircuit,
      });
      if (raw is Map) return Map<String, dynamic>.from(raw);
    } catch (e) {
      if (kDebugMode) debugPrint('[omni_mdm] runSynchronized: $e');
    }
    return {'ok': false, 'error': 'run_failed'};
  }
}
