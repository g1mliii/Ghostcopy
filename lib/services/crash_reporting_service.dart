import 'dart:async';

export 'impl/crash_reporting_service.dart';

/// Reports crashes and errors from the running app.
///
/// Wraps the whole app, startup included, so an error that stops the app
/// coming up is reported too. See SentryCrashReportingService for what is and
/// is not sent.
// One member, and still an interface: every service here sits behind one
// (see CLAUDE.md), so startup can be given another implementation.
// ignore: one_member_abstracts
abstract class ICrashReportingService {
  /// Run [app] with crash reporting around it.
  Future<void> run(FutureOr<void> Function() app);
}
