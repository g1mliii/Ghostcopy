import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

/// The HTTP client every Supabase request goes through, with a deadline.
///
/// Without one a request waits for ever. After the Mac slept, a request could
/// go out on a connection that died while it was asleep and never hear back -
/// and when that request is the token refresh, every later request queues
/// behind it: the device list spun indefinitely, history stopped loading and
/// realtime could not rejoin, until the app was restarted. With a deadline
/// the stuck request fails, the next one opens a fresh connection, and the
/// caller sees a network error it can report and retry.
class TimeoutHttpClient extends http.BaseClient {
  TimeoutHttpClient({
    http.Client? inner,
    this.timeout = const Duration(seconds: 20),
    this.uploadTimeout = const Duration(minutes: 5),
  }) : _inner = inner ?? _defaultInner();

  final http.Client _inner;

  /// For an ordinary request: time until the response headers arrive.
  final Duration timeout;

  /// For a request with a large body, whose upload counts against the clock -
  /// a 10 MB file on a slow connection.
  final Duration uploadTimeout;

  /// Bodies above this count as uploads.
  static const uploadThresholdBytes = 256 * 1024;

  static http.Client _defaultInner() => IOClient(
    HttpClient()
      ..connectionTimeout = const Duration(seconds: 10)
      ..idleTimeout = const Duration(seconds: 15),
  );

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    final isUpload = (request.contentLength ?? 0) > uploadThresholdBytes;
    return _inner.send(request).timeout(isUpload ? uploadTimeout : timeout);
  }

  @override
  void close() => _inner.close();
}
