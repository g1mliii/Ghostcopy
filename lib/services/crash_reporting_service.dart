import 'dart:async';

export 'impl/crash_reporting_service.dart';

/// Reports crashes and errors from the running app.
///
/// Wraps the whole app, startup included, so an error that stops the app
/// coming up is reported too. See SentryCrashReportingService for what is and
/// is not sent.
abstract class ICrashReportingService {
  /// Run [app] with crash reporting around it.
  Future<void> run(FutureOr<void> Function() app);

  /// Report an error the app recovered from.
  ///
  /// For the failures startup deliberately continues past. They still need to
  /// be visible - a device that never registers is a real fault - but they
  /// reach Sentry as a handled error rather than through the unhandled-error
  /// handler, which marks everything it receives `level: fatal`. [context]
  /// says which step failed, and must not contain clipboard content.
  Future<void> reportHandled(
    Object error,
    StackTrace stackTrace, {
    required String context,
  });
}
