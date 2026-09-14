import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';

import '../config/omni_mdm_config.dart';
import '../session/omni_session.dart';

typedef MqttMessageHandler = void Function(String topic, List<int> payload);

/// Cliente MQTT compartido: telemetría, comandos y manifiesto.
class OmniMqttClient {
  OmniMqttClient(this._config, this._session);

  final OmniMdmConfig _config;
  final OmniSession _session;
  MqttServerClient? _client;
  final Map<String, MqttMessageHandler> _handlers = {};
  String? _lastError;
  DateTime? _lastConnectAttemptAt;

  bool get isConnected =>
      _client?.connectionStatus?.state == MqttConnectionState.connected;

  String? get lastError => _lastError;

  Future<bool> ensureConnected() async {
    final mqttUrl = _config.mqttUrl;
    final instanceId = _session.instanceId;
    if (mqttUrl == null || mqttUrl.trim().isEmpty) {
      _lastError = 'MQTT URL no configurada';
      return false;
    }
    if (instanceId == null || instanceId.isEmpty) {
      _lastError = 'Sin instanceId (enroll pendiente)';
      return false;
    }
    if (isConnected) {
      _lastError = null;
      return true;
    }
    try {
      _lastConnectAttemptAt = DateTime.now().toUtc();
      final uri = _parseMqttUri(mqttUrl);
      if (uri.host.isEmpty) {
        _lastError = 'Host MQTT inválido: $mqttUrl';
        return false;
      }
      final port = uri.hasPort ? uri.port : (uri.scheme == 'mqtts' ? 8883 : 1883);
      final client = MqttServerClient.withPort(
        uri.host,
        'omni_$instanceId',
        port,
      );
      client.logging(on: kDebugMode);
      client.keepAlivePeriod = 30;
      client.connectTimeoutPeriod = 15000;
      client.autoReconnect = true;
      client.resubscribeOnAutoReconnect = true;
      client.setProtocolV311();
      if (uri.scheme == 'mqtts') {
        client.secure = true;
      }
      client.onConnected = _onConnected;
      client.onDisconnected = () {
        if (kDebugMode) debugPrint('[omni_mdm] mqtt disconnected');
      };
      client.onAutoReconnect = () {
        if (kDebugMode) debugPrint('[omni_mdm] mqtt auto-reconnect…');
      };
      client.onSubscribed = (topic) {
        if (kDebugMode) debugPrint('[omni_mdm] mqtt subscribed $topic');
      };
      client.updates?.listen((events) {
        for (final e in events) {
          final rec = e.payload as MqttPublishMessage;
          final topic = e.topic;
          final payload = rec.payload.message;
          _handlers[topic]?.call(topic, payload);
        }
      });

      final connMess = MqttConnectMessage()
          .withClientIdentifier('omni_$instanceId')
          .startClean()
          .withWillQos(MqttQos.atLeastOnce);
      client.connectionMessage = connMess;

      if (kDebugMode) {
        debugPrint(
          '[omni_mdm] mqtt connecting host=${uri.host} port=$port '
          'url=$mqttUrl attempt=$_lastConnectAttemptAt',
        );
      }

      await client.connect();
      _client = client;
      if (isConnected) {
        _lastError = null;
        if (kDebugMode) {
          debugPrint('[omni_mdm] mqtt connected ${uri.host}:$port');
        }
        return true;
      }
      final state = client.connectionStatus?.state;
      final rc = client.connectionStatus?.returnCode;
      _lastError = 'No conectado (state=$state returnCode=$rc) host=${uri.host}:$port';
      client.disconnect();
      return false;
    } catch (e) {
      _lastError = e.toString();
      if (kDebugMode) debugPrint('[omni_mdm] mqtt connect failed: $e');
      return false;
    }
  }

  Uri _parseMqttUri(String raw) {
    final trimmed = raw.trim();
    // Dart Uri requiere esquema http-like; mqtt:// funciona en Uri.parse.
    try {
      final uri = Uri.parse(trimmed);
      if (uri.host.isNotEmpty) return uri;
    } catch (_) {}
    // Fallback host:port sin esquema.
    if (trimmed.contains(':') && !trimmed.contains('://')) {
      final parts = trimmed.split(':');
      final host = parts.first;
      final port = int.tryParse(parts.length > 1 ? parts[1] : '') ?? 1883;
      return Uri(scheme: 'mqtt', host: host, port: port);
    }
    return Uri(scheme: 'mqtt', host: trimmed, port: 1883);
  }

  void _onConnected() {
    final businessId = _session.businessId;
    final instanceId = _session.instanceId;
    if (businessId == null || instanceId == null) return;
    subscribe('omni/$businessId/$instanceId/cmd/request', _dispatchTopic);
    subscribe('omni/$businessId/$instanceId/shadow/desired', _dispatchTopic);
  }

  void _dispatchTopic(String topic, List<int> payload) {
    _handlers[topic]?.call(topic, payload);
  }

  void subscribe(String topic, MqttMessageHandler handler) {
    _handlers[topic] = handler;
    final client = _client;
    if (client != null && isConnected) {
      client.subscribe(topic, MqttQos.atLeastOnce);
    }
  }

  Future<bool> publish(
    String topic,
    Map<String, dynamic> body, {
    MqttQos qos = MqttQos.atLeastOnce,
  }) async {
    if (!await ensureConnected()) return false;
    final client = _client!;
    client.publishMessage(
      topic,
      qos,
      MqttClientPayloadBuilder().addString(jsonEncode(body)).payload!,
    );
    return true;
  }

  String topic(String suffix) {
    return 'omni/${_session.businessId}/${_session.instanceId}/$suffix';
  }

  void dispose() {
    _client?.disconnect();
    _client = null;
    _handlers.clear();
  }

  Future<void> disconnect() async {
    dispose();
  }
}
