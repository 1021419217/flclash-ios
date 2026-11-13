import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:flutter/foundation.dart';

import 'print.dart';
import 'protocol.dart';
import 'string.dart';

String? profileUrlFromQrCodes(Iterable<String?> values) {
  for (final value in values) {
    final text = value?.trim();
    if (text == null || text.isEmpty) {
      continue;
    }
    if (text.isUrl || text.isShareLink) {
      return text;
    }
    final uri = Uri.tryParse(text);
    if (uri == null || !protocolSchemes.contains(uri.scheme)) {
      continue;
    }
    final url = _installConfigUrl(uri);
    if (url != null && url.isUrl) {
      return url;
    }
  }
  return null;
}

String? _installConfigUrl(Uri uri) {
  // Providers ship `clash://install-config?url=...`, `clash://?url=...` and the
  // bare `clash://?url=` form; all of them carry the subscription in `url`.
  if (uri.host.isNotEmpty && uri.host != 'install-config') {
    return null;
  }
  final url = uri.queryParameters['url']?.trim();
  return url == null || url.isEmpty ? null : url;
}

class LinkManager {
  static LinkManager? _instance;
  StreamSubscription? subscription;
  Uri? _pendingUri;
  String? _lastUrl;
  DateTime? _lastUrlAt;

  LinkManager._internal();

  @visibleForTesting
  Stream<Uri> Function() uriLinkStream = () => AppLinks().uriLinkStream;

  @visibleForTesting
  Future<Uri?> Function() initialLink = () => AppLinks().getInitialLink();

  /// Linux argv: the gtk plugin hooks GApplication too late to see it.
  void seedInitialLink(List<String> args) {
    for (final arg in args) {
      final uri = Uri.tryParse(arg);
      if (uri != null && protocolSchemes.contains(uri.scheme)) {
        _pendingUri = uri;
        return;
      }
    }
  }

  Future<void> initAppLinksListen(
    Function(String url) installConfigCallBack,
  ) async {
    destroy();
    try {
      subscription = uriLinkStream().listen(
        (uri) {
          _handle(uri, installConfigCallBack);
        },
        onError: (Object error) {
          commonPrint.log(
            'app links error: $error',
            logLevel: LogLevel.warning,
          );
        },
      );
    } catch (error) {
      commonPrint.log(
        'app links unavailable: $error',
        logLevel: LogLevel.warning,
      );
    }
    // The stream only carries links delivered after it starts listening; on a
    // cold start the URL already reached the plugin before Dart was up.
    try {
      final initial = await initialLink();
      if (initial != null) {
        _handle(initial, installConfigCallBack);
      }
    } catch (error) {
      commonPrint.log(
        'initial link unavailable: $error',
        logLevel: LogLevel.warning,
      );
    }
    final pending = _pendingUri;
    _pendingUri = null;
    if (pending != null) {
      _handle(pending, installConfigCallBack);
    }
  }

  void _handle(Uri uri, Function(String url) installConfigCallBack) {
    commonPrint.log('onAppLink: $uri');
    final url = _installConfigUrl(uri);
    if (url == null) {
      return;
    }
    // The initial link and the stream can carry the same URL; ask once.
    final now = DateTime.now();
    if (url == _lastUrl &&
        _lastUrlAt != null &&
        now.difference(_lastUrlAt!) < const Duration(seconds: 3)) {
      return;
    }
    _lastUrl = url;
    _lastUrlAt = now;
    installConfigCallBack(url);
  }

  void destroy() {
    if (subscription != null) {
      subscription?.cancel();
      subscription = null;
    }
  }

  factory LinkManager() {
    _instance ??= LinkManager._internal();
    return _instance!;
  }
}

final linkManager = LinkManager();
