import 'package:flutter/widgets.dart';

import '../omni_mdm.dart';

/// Captura de pantallas y HTTP. El envío lo hace [OmniEventSync], no el host.
abstract final class OmniCapture {
  static Future<void> screen({
    required String name,
    String? previous,
  }) {
    return OmniMdm.logEvent(
      type: 'navigation',
      name: 'screen_view',
      payload: {
        'screen': name,
        if (previous != null) 'previous': previous,
      },
    );
  }

  static Future<void> http({
    required String method,
    required String url,
    int? statusCode,
    int? durationMs,
    String? requestBody,
    String? responseBody,
    String? error,
    String? traceId,
  }) {
    return OmniMdm.logEvent(
      type: 'http',
      name: '$method $url',
      payload: {
        'method': method,
        'url': url,
        if (statusCode != null) 'status': statusCode,
        if (durationMs != null) 'duration_ms': durationMs,
        if (traceId != null) 'trace_id': traceId,
        if (requestBody != null) 'request': requestBody,
        if (responseBody != null) 'response': responseBody,
        if (error != null) 'error': error,
      },
    );
  }
}

/// Observer de navegación agnóstico. No conoce tenants ni ERP.
class OmniNavigationObserver extends NavigatorObserver {
  OmniNavigationObserver({this.onScreen});

  final void Function(String screen)? onScreen;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _emit(route, previousRoute);
    super.didPush(route, previousRoute);
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    if (newRoute != null) _emit(newRoute, oldRoute);
    super.didReplace(newRoute: newRoute, oldRoute: oldRoute);
  }

  void _emit(Route<dynamic> route, Route<dynamic>? previous) {
    final name = route.settings.name;
    if (name == null || name.isEmpty) return;
    onScreen?.call(name);
    OmniCapture.screen(
      name: name,
      previous: previous?.settings.name,
    );
  }
}
