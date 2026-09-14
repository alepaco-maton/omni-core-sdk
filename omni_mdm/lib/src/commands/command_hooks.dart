/// Callbacks opcionales tras ejecutar comandos MQTT (evita dependencia circular).
typedef CommandSucceededHook = Future<void> Function(
  String capability,
  Map<String, dynamic> result,
);

CommandSucceededHook? onCommandSucceeded;
