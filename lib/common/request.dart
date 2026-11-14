import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/plugins/app.dart';
import 'package:fl_clash/state.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path/path.dart' show join;

class Request {
  late final Dio dio;
  late final Dio _clashDio;

  /// Straight out of the device, for one retry when the core's port is not
  /// listening yet.
  late final Dio _directDio;

  /// Refuses an untrusted certificate even with the certificate check turned
  /// off, because what it fetches is installed, on Windows as administrator.
  @visibleForTesting
  late final Dio releaseDio;
  String? userAgent;

  ProviderReader? _read;

  void attach(ProviderReader read) {
    _read = read;
  }

  Request() {
    dio = Dio(BaseOptions(headers: {'User-Agent': browserUa}));
    _clashDio = Dio();
    _clashDio.httpClientAdapter = IOHttpClientAdapter(
      createHttpClient: () {
        final client = HttpClient();
        client.findProxy = (Uri uri) {
          client.userAgent = globalState.ua;
          return _findProxy(uri);
        };
        return client;
      },
    );
    _directDio = Dio();
    _directDio.httpClientAdapter = IOHttpClientAdapter(
      createHttpClient: () {
        return HttpClient()
          ..userAgent = globalState.ua
          ..findProxy = ((_) => 'DIRECT');
      },
    );
    releaseDio = Dio(BaseOptions(headers: {'User-Agent': browserUa}));
    releaseDio.httpClientAdapter = IOHttpClientAdapter(
      createHttpClient: () {
        return HttpClient()
          ..badCertificateCallback = ((_, _, _) => false)
          ..findProxy = _findProxy;
      },
    );
  }

  String _findProxy(Uri uri) {
    final read = _read;
    if (read == null) {
      return 'DIRECT';
    }
    return FlClashHttpOverrides.findProxyForReader(read, uri);
  }

  /// Airport panels (V2Board / XBoard / SSPanel) and Cloudflare bot filters
  /// reject unknown clients with 401/403/406 before serving the subscription.
  /// Retrying the same body with a set of well-known client User-Agents gets
  /// past most of them without any user-visible setting.
  static const _subscriptionUserAgents = [
    'clash-verge/v2.4.2 ClashforWindows/0.20.39 Clash.Meta',
    'ClashforWindows/0.20.39',
    'Shadowrocket/2.2.35 (iOS 18.1; iPhone)',
    'Mozilla/5.0 (iPhone; CPU iPhone OS 18_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.1 Mobile/15E148 Safari/604.1',
    'clash.meta',
  ];

  List<String> _userAgentCandidates() => <String>[
    if (globalState.ua.isNotEmpty) globalState.ua,
    ..._subscriptionUserAgents,
  ].toSet().toList();

  Map<String, Object> _subscriptionHeaders(
    ({Uri uri, Map<String, Object> headers}) target,
    String ua,
  ) => <String, Object>{
    ...target.headers,
    'User-Agent': ua,
    'Accept': '*/*',
    'Accept-Language': 'zh-CN,zh-Hans;q=0.9,en;q=0.8',
  };

  Future<Response<T>> _download<T>(String url, ResponseType responseType) async {
    final target = downloadTarget(url);
    final candidates = _userAgentCandidates();
    DioException? lastRejection;
    for (final ua in candidates) {
      final attempt = (
        uri: target.uri,
        headers: _subscriptionHeaders(target, ua),
      );
      try {
        return await _get<T>(attempt, responseType, url, _clashDio);
      } on DioException catch (error) {
        final status = error.response?.statusCode;
        if (status == 401 || status == 403 || status == 406) {
          lastRejection = error;
          commonPrint.log(
            'Download $url with UA "$ua" returned $status, trying next UA candidate',
            logLevel: LogLevel.warning,
          );
          continue;
        }
        // The proxy this build downloads through is its own core, so while the
        // tunnel is still starting the port is closed and every import dies at
        // connect — leaving no way to add a profile and find out why. One
        // direct retry gets the profile in.
        if (!_isConnectFailure(error) || error.requestOptions.extra['direct'] == true) {
          rethrow;
        }
        commonPrint.log(
          'proxy download failed, retrying direct: ${compactError(error)}',
          logLevel: LogLevel.warning,
        );
        return _get<T>(attempt, responseType, url, _directDio, extra: const {'direct': true});
      }
    }
    // Every known UA was rejected. Some panels only answer a plain direct
    // request, so try that once before surfacing the 403.
    if (lastRejection != null) {
      final direct = (
        uri: target.uri,
        headers: _subscriptionHeaders(target, _subscriptionUserAgents.first),
      );
      try {
        return await _get<T>(
          direct,
          responseType,
          url,
          _directDio,
          extra: const {'direct': true},
        );
      } catch (_) {
        throw lastRejection;
      }
    }
    throw StateError('no user agent candidates');
  }

  Future<Response<T>> _get<T>(
    ({Uri uri, Map<String, Object> headers}) target,
    ResponseType responseType,
    String url,
    Dio client, {
    Map<String, Object> extra = const {},
  }) {
    final cancelToken = CancelToken();
    return client
        .getUri<T>(
          target.uri,
          options: Options(
            responseType: responseType,
            headers: target.headers,
            extra: extra,
          ),
          cancelToken: cancelToken,
        )
        .timeout(
          downloadTimeoutDuration,
          onTimeout: () {
            cancelToken.cancel();
            throw DioException.receiveTimeout(
              timeout: downloadTimeoutDuration,
              requestOptions: RequestOptions(path: url, extra: extra),
            );
          },
        );
  }

  static bool _isConnectFailure(DioException error) => switch (error.type) {
    DioExceptionType.connectionError ||
    DioExceptionType.connectionTimeout ||
    DioExceptionType.unknown => true,
    _ => false,
  };

  Future<Response<Uint8List>> getFileResponseForUrl(String url) async {
    try {
      return await _download<Uint8List>(url, ResponseType.bytes);
    } catch (e) {
      commonPrint.log(
        'getFileResponseForUrl error ${compactError(e)}',
        logLevel: LogLevel.warning,
      );
      rethrow;
    }
  }

  Future<Response<String>> getTextResponseForUrl(String url) async {
    try {
      return await _download<String>(url, ResponseType.plain);
    } catch (e) {
      commonPrint.log(
        'getTextResponseForUrl error ${compactError(e)}',
        logLevel: LogLevel.warning,
      );
      rethrow;
    }
  }

  /// Null when this build is current; throws when GitHub cannot be asked.
  Future<Map<String, dynamic>?> checkForUpdate() async {
    final release = await latestRelease();
    final remoteVersion = release['tag_name'] as String;
    final version = globalState.packageInfo.version;
    final hasUpdate =
        compareVersions(remoteVersion.replaceAll('v', ''), version) > 0;
    return hasUpdate ? release : null;
  }

  /// The release page redirect still answers once the hourly API quota is spent.
  Future<Map<String, dynamic>> latestRelease() async {
    try {
      final response = await dio.get<Map<String, dynamic>>(
        'https://api.github.com/repos/$repository/releases/latest',
        options: Options(responseType: ResponseType.json),
      );
      return response.data!;
    } on DioException catch (error) {
      commonPrint.log(
        'latest release API failed: ${compactError(error)}',
        logLevel: LogLevel.warning,
      );
    }
    final response = await dio.get<void>(
      'https://github.com/$repository/releases/latest',
      options: Options(
        followRedirects: false,
        validateStatus: (status) => status != null && status < 400,
      ),
    );
    final location = response.headers.value(HttpHeaders.locationHeader);
    final segments = Uri.tryParse(location ?? '')?.pathSegments ?? const [];
    final tagIndex = segments.indexOf('tag') + 1;
    if (tagIndex == 0 || tagIndex >= segments.length) {
      throw FormatException('No release tag in the redirect', location);
    }
    return {'tag_name': segments[tagIndex]};
  }

  Future<String> downloadVerifiedRelease({
    required String tag,
    required String name,
    required String directory,
    ProgressCallback? onReceiveProgress,
    CancelToken? cancelToken,
  }) async {
    final sums = await releaseDio.getUri<String>(
      releaseAssetUri(tag, releaseChecksumsName),
      options: Options(responseType: ResponseType.plain),
      cancelToken: cancelToken,
    );
    final expected = releaseChecksum(sums.data ?? '', name);
    if (expected == null) {
      throw ReleaseNotVerifiedException(name);
    }
    final path = join(directory, name);
    final uri = releaseAssetUri(tag, name);
    if (app case final android?) {
      await android.downloadFile(
        uri,
        path,
        title: name,
        onReceiveProgress: onReceiveProgress ?? (_, _) {},
        cancelToken: cancelToken ?? CancelToken(),
      );
    } else {
      await releaseDio.downloadUri(
        uri,
        path,
        onReceiveProgress: onReceiveProgress,
        cancelToken: cancelToken,
      );
    }
    if (await fileSha256(path) != expected) {
      throw ReleaseNotVerifiedException(name);
    }
    return path;
  }
}

final request = Request();

/// Some subscription servers send a gzip or zlib body without saying so in
/// Content-Encoding, which is the only signal dart:io decompresses on.
Uint8List decompressUnlabeled(Uint8List bytes) {
  final codec = switch (bytes) {
    [0x1f, 0x8b, ...] => gzip,
    [0x78, final flags, ...] when (0x78 << 8 | flags) % 31 == 0 => zlib,
    _ => null,
  };
  if (codec == null) {
    return bytes;
  }
  try {
    return Uint8List.fromList(codec.decode(bytes));
  } on FormatException {
    return bytes;
  }
}

/// dart:io turns [Uri.userInfo] into Basic credentials still percent-encoded.
@visibleForTesting
({Uri uri, Map<String, Object> headers}) downloadTarget(String url) {
  final uri = url.webUri ?? Uri.parse(url);
  if (uri.userInfo.isEmpty) {
    return (uri: uri, headers: const {});
  }
  final credentials = uri.userInfo.split(':').map(_decodeUserInfo).join(':');
  return (
    uri: uri.replace(userInfo: ''),
    headers: {
      HttpHeaders.authorizationHeader:
          'Basic ${base64.encode(utf8.encode(credentials))}',
    },
  );
}

String _decodeUserInfo(String value) {
  try {
    return Uri.decodeComponent(value);
  } on ArgumentError {
    return value;
  }
}

String? getFileNameForDisposition(String? disposition) {
  if (disposition == null) return null;
  final parseValue = HeaderValue.parse(disposition);
  final parameters = parseValue.parameters;
  final fileNamePointKey = parameters.keys.firstWhere(
    (key) => key == 'filename*',
    orElse: () => '',
  );
  if (fileNamePointKey.isNotEmpty) {
    final res = parameters[fileNamePointKey]?.split("''") ?? [];
    if (res.length >= 2) {
      return Uri.decodeComponent(res[1]);
    }
  }
  final fileNameKey = parameters.keys.firstWhere(
    (key) => key == 'filename',
    orElse: () => '',
  );
  if (fileNameKey.isEmpty) return null;
  return parameters[fileNameKey];
}
