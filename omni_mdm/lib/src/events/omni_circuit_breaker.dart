import 'dart:io';

/// Circuito cerrado → abierto tras N fallos → half-open tras [openSec] → cerrado si el probe ok.
/// Fail-open: la app anfitriona nunca se bloquea; solo se deja de empujar red.
class OmniCircuitBreaker {
  OmniCircuitBreaker();

  String state = 'closed';
  int failures = 0;
  DateTime? openedAt;
  String connectivity = 'unknown';
  String lastError = '';

  int failThreshold = 3;
  int openSec = 60;
  int probeTimeoutMs = 8000;

  bool get isOpen => state == 'open';

  bool allowRequest() {
    if (state != 'open') return true;
    final opened = openedAt;
    if (opened == null) return true;
    if (DateTime.now().difference(opened).inSeconds >= openSec) {
      state = 'half_open';
      return true;
    }
    return false;
  }

  int retryInSec() {
    final opened = openedAt;
    if (opened == null) return openSec;
    final left = openSec - DateTime.now().difference(opened).inSeconds;
    return left < 1 ? 1 : left;
  }

  void onSuccess() {
    state = 'closed';
    failures = 0;
    connectivity = 'online';
    lastError = '';
  }

  void onFailure(Object error) {
    lastError = error.toString();
    final noNet = error is SocketException ||
        (error is HttpException) ||
        lastError.contains('SocketException') ||
        lastError.contains('Failed host lookup') ||
        lastError.contains('Network is unreachable');
    connectivity = noNet ? 'no_network' : 'server_down';
    if (state == 'half_open') {
      _open();
      return;
    }
    failures += 1;
    final threshold = noNet ? 1 : failThreshold;
    if (failures >= threshold) {
      _open();
    }
  }

  void applySettings(Map json) {
    failThreshold = (json['cb_fail_threshold'] as num?)?.toInt() ?? failThreshold;
    openSec = (json['cb_open_sec'] as num?)?.toInt() ?? openSec;
    probeTimeoutMs = (json['probe_timeout_ms'] as num?)?.toInt() ?? probeTimeoutMs;
  }

  void _open() {
    state = 'open';
    openedAt = DateTime.now();
  }

  Map<String, Object?> snapshot() => {
        'circuit': state,
        'failures': failures,
        'connectivity': connectivity,
        'last_error': lastError,
      };
}
