import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';

import '../config/omni_mdm_config.dart';
import '../session/omni_session.dart';

typedef MqttMessageHandler = void Function(String topic, List<int> payload);

/// Cliente MQTT: TCP (`mqtt://`) o WebSocket (`ws://` / `wss://`).
///
/// Notas EMQX/WSS:
/// - URL base **sin puerto** en el string (`wss://host/mqtt`) + `client.port`.
/// - No usar `withWillQos` sin Will Topic (MQTT 3.1.1: Will QoS debe ser 0 si Will Flag=0;
///   EMQX puede cerrar sin CONNACK → "broker is not responding").
/// - `onBadCertificate`: cadena LE YE1 a veces falla en trust store Android/Windows.
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

    // Descartar cliente a medio conectar de un intento previo.
    _client?.disconnect();
    _client = null;

    try {
      _lastConnectAttemptAt = DateTime.now().toUtc();
      final uri = _parseMqttUri(mqttUrl);
      if (uri.host.isEmpty) {
        _lastError = 'Host MQTT inválido: $mqttUrl';
        return false;
      }
      final useWs = uri.scheme == 'ws' || uri.scheme == 'wss';
      final useWss = uri.scheme == 'wss';
      final port = uri.hasPort
          ? uri.port
          : (useWs
              ? (useWss ? 443 : 80)
              : (uri.scheme == 'mqtts' ? 8883 : 1883));

      final path = (uri.path.isEmpty || uri.path == '/') ? '/mqtt' : uri.path;
      // mqtt_client: el "server" para WS no debe llevar puerto; va en client.port.
      final server = useWs
          ? '${uri.scheme}://${uri.host}$path'
          : uri.host;
      final clientId = _safeClientId(instanceId);

      final client = MqttServerClient(server, clientId);
      client.port = port;
      client.logging(on: kDebugMode);
      client.keepAlivePeriod = 60;
      client.connectTimeoutPeriod = 15000;
      client.autoReconnect = false;
      client.resubscribeOnAutoReconnect = true;
      client.setProtocolV311();

      if (useWs) {
        client.useWebSocket = true;
        // EMQX espera un solo subprotocolo.
        client.websocketProtocols = MqttClientConstants.protocolsSingleDefault;
        client.onBadCertificate = (Object _) => true;
      } else if (uri.scheme == 'mqtts') {
        client.secure = true;
        client.onBadCertificate = (Object _) => true;
        client.securityContext = SecurityContext.defaultContext;
      }

      client.onConnected = _onConnected;
      client.onDisconnected = () {
        if (kDebugMode) debugPrint('[omni_mdm] mqtt disconnected');
      };

      // CONNECT limpio: sin Will. Auth opcional (EMQX lab permite anónimo).
      final connMess = MqttConnectMessage()
          .withClientIdentifier(clientId)
          .startClean()
          .keepAliveFor(60);
      final token = _session.instanceToken;
      final user = instanceId;
      final pass = (token != null && token.isNotEmpty) ? token : null;
      if (pass != null) {
        connMess.authenticateAs(user, pass);
      }
      client.connectionMessage = connMess;

      if (kDebugMode) {
        debugPrint(
          '[omni_mdm] mqtt connecting server=$server port=$port '
          'ws=$useWs auth=${pass != null} attempt=$_lastConnectAttemptAt',
        );
      }

      // Si no hay password, connect() sin args (no enviar user vacío).
      if (pass != null) {
        await client.connect(user, pass);
      } else {
        await client.connect();
      }
      _client = client;

      if (isConnected) {
        _lastError = null;
        client.autoReconnect = true;
        client.updates?.listen((events) {
          for (final e in events) {
            final rec = e.payload as MqttPublishMessage;
            _handlers[e.topic]?.call(e.topic, rec.payload.message);
          }
        });
        if (kDebugMode) {
          debugPrint('[omni_mdm] mqtt connected $server:$port ws=$useWs');
        }
        return true;
      }

      final state = client.connectionStatus?.state;
      final rc = client.connectionStatus?.returnCode;
      _lastError =
          'No conectado (state=$state returnCode=$rc) $server:$port';
      client.disconnect();
      return false;
    } catch (e) {
      _lastError = e.toString();
      if (kDebugMode) debugPrint('[omni_mdm] mqtt connect failed: $e');
      return false;
    }
  }

  /// MQTT 3.1.1 recomienda clientId corto; EMQX acepta más. Evitar caracteres raros.
  String _safeClientId(String instanceId) {
    final raw = 'omni_${instanceId.replaceAll('-', '')}';
    if (raw.length <= 48) return raw;
    return raw.substring(0, 48);
  }

  Uri _parseMqttUri(String raw) {
    var trimmed = raw.trim();
    // Fragmentos residuales (#) rompen el path en algunos stacks.
    final hash = trimmed.indexOf('#');
    if (hash >= 0) trimmed = trimmed.substring(0, hash);
    try {
      final uri = Uri.parse(trimmed);
      if (uri.host.isNotEmpty) return uri;
    } catch (_) {}
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
