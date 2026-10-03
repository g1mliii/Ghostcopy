import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;
import 'package:sentry_flutter/sentry_flutter.dart';

import '../crash_reporting_service.dart';
import '../packaged_app_data.dart';

/// The GhostCopy Sentry project (spiderweb/flutter). A DSN only lets a client
/// submit events - it grants no read access - so, like the Supabase
/// publishable key in main.dart, it is compiled in rather than hidden.
const _sentryDsn =
    'https://e0c0077d7dadc346ef2e6b41d508f583@o4511233616969728.ingest.us.sentry.io/4512145211392000';

/// Crash reporting through Sentry, in release builds only.
///
/// Debug and profile builds run the app directly: their errors are for the
/// developer's console, not the project's issue list.
class SentryCrashReportingService implements ICrashReportingService {
  SentryCrashReportingService({bool? enabled})
    : _enabled = enabled ?? kReleaseMode;

  final bool _enabled;

  @override
  Future<void> run(FutureOr<void> Function() app) async {
    if (!_enabled) {
      await app();
      return;
    }
    await SentryFlutter.init(configureCrashReporting, appRunner: app);
  }

  @override
  Future<void> reportHandled(
    Object error,
    StackTrace stackTrace, {
    required String context,
  }) async {
    debugPrint('[CrashReporting] $context: $error');
    if (!_enabled) return;
    // The same beforeSend scrubbing applies to these as to crashes; the
    // context is a fixed string from the call site, never user content.
    await Sentry.captureException(
      error,
      stackTrace: stackTrace,
      withScope: (scope) => scope.setTag('startup_step', context),
    );
  }
}

/// Sentry settings, chosen for an app whose whole job is carrying other
/// people's clipboard contents: crashes and errors only, and nothing that
/// could hold a clip.
@visibleForTesting
void configureCrashReporting(SentryFlutterOptions options) {
  options
    ..dsn = _sentryDsn
    ..environment = 'production'
    // No IP address or device user name on events.
    ..sendDefaultPii = false
    // A screenshot would show the composer and history. (The widget tree,
    // attachViewHierarchy, is off by default and stays that way.)
    ..attachScreenshot = false
    // debugPrint output names files and counts clips; it stays on the device.
    ..enablePrintBreadcrumbs = false
    ..enableUserInteractionBreadcrumbs = false
    // Native breadcrumbs (system events, and network calls made by plugins
    // with their URLs) are recorded by the iOS/Android/macOS SDKs and never
    // pass through beforeSend below, so nothing here could scrub them.
    ..enableAutoNativeBreadcrumbs = false
    // Sessions report every launch and its length whether or not anything
    // went wrong. Errors and crashes only.
    ..enableAutoSessionTracking = false
    // Errors only. Performance was profiled directly (docs/*-performance.md),
    // and tracing costs CPU on an app that must idle at zero.
    ..enableAutoPerformanceTracing = false
    ..enableUserInteractionTracing = false
    ..enableFramesTracking = false
    ..tracesSampleRate = null
    // Kept at their defaults: app-hang (iOS, macOS) and ANR (Android) reports,
    // declared on the App Store as Performance Data, not linked to the user.
    // Native crash handling stays on too: a native crash report is a signal
    // or exception name and a stack. Its reason text is the one thing the
    // Dart-side scrubbing below cannot reach.
    // Foreground, background and low-memory warnings, recorded from Dart so
    // they go through scrubBreadcrumb like everything else. Without them a
    // report cannot tell apart the three ways a phone app dies in the
    // foreground: out of memory (memory warnings first), frozen and killed,
    // or frozen and force-quit - which Sentry also files as a
    // WatchdogTermination, because a frozen app cannot record that it left
    // the foreground. FLUTTER-7 arrived with nothing to go on.
    ..enableAppLifecycleBreadcrumbs = true
    ..enableMemoryPressureBreadcrumbs = true
    ..maxBreadcrumbs = 40
    ..nativeDatabasePath = _nativeDatabasePath()
    ..beforeSend = scrubEvent
    ..beforeBreadcrumb = scrubBreadcrumb;
}

/// Where sentry-native keeps its crash database on Windows and Linux.
///
/// Left unset it defaults to `.sentry-native` in the *current working
/// directory*, which is only ever right by accident. Launched from the Start
/// menu the working directory is not the app's own, and in an MSIX package the
/// install directory is read-only - so the database cannot be created, and
/// native crashes are dropped with nothing to say so. Running a build from the
/// repository root is what makes it look fine: the folder appears next to the
/// source and everything works.
///
/// `%LOCALAPPDATA%` is the right home for an unpackaged build. A Store
/// install uses its package's LocalCache instead: measured by sideloading on
/// 2026-09-25, a full-trust MSIX does NOT redirect writes under
/// `%LOCALAPPDATA%` into the package, so the database landed in the real
/// folder - where uninstalling left it. See PackagedAppData.
///
/// Returns null on platforms that do not use sentry-native (iOS, Android,
/// macOS have their own), and on a Windows session with no LOCALAPPDATA, where
/// the default is no worse than a path built from nothing.
String? _nativeDatabasePath() {
  if (!Platform.isWindows && !Platform.isLinux) return null;

  // A Store install keeps it in the package, which Windows deletes with it -
  // by package identity, not by whether the move finished: a launch whose
  // move had to stop startup still reports through here, and its database
  // must not land in AppData either.
  final packaged = PackagedAppData.thisPackage;
  if (packaged != null) return path.join(packaged.localCache, 'sentry-native');

  final home = Platform.environment['HOME'];
  final root = Platform.isWindows
      ? Platform.environment['LOCALAPPDATA']
      : Platform.environment['XDG_CACHE_HOME'] ??
            (home == null ? null : path.join(home, '.cache'));
  if (root == null || root.isEmpty) return null;

  return PackagedAppData.unpackagedCrashDatabase(root);
}

// Anything quoted is treated as content: exception messages quote the value
// they choked on - a path, a JSON fragment, a filename - and for this app
// that value is often a clip.
final _quoted = RegExp('''"[^"]*"|'[^']*'|“[^”]*”|‘[^’]*’''');
// Postgres puts the offending row values in detail text:
// Key (fcm_token)=(abc...) already exists.
final _keyValue = RegExp(r'\)=\([^)]*\)');
// Signed storage URLs carry credentials in the query string.
final _urlQuery = RegExp(r'(https?://[^\s?#]+)[?#]\S*');
const _maxTextLength = 200;

/// A message or exception value with anything that could be content removed.
///
/// First line only: exceptions put the text they choked on after it,
/// unquoted - Dart's FormatException prints the source on the next line,
/// which for this app is often the clip itself.
@visibleForTesting
String? redact(String? text) {
  if (text == null) return null;
  final firstLine = text.split('\n').first.trimRight();
  var out = firstLine
      .replaceAll(_quoted, '[redacted]')
      .replaceAll(_keyValue, ')=([redacted])')
      .replaceAllMapped(_urlQuery, (m) => m[1]!);
  if (out.length > _maxTextLength) {
    out = '${out.substring(0, _maxTextLength)}…';
  }
  return out;
}

/// Strip clip content from an event before it leaves the device.
@visibleForTesting
FutureOr<SentryEvent?> scrubEvent(SentryEvent event, Hint hint) {
  final message = event.message;
  if (message != null) {
    event.message = SentryMessage(redact(message.formatted) ?? '');
  }
  for (final exception in event.exceptions ?? const <SentryException>[]) {
    exception.value = redact(exception.value);
  }
  event
    ..breadcrumbs = event.breadcrumbs
        ?.map((b) => scrubBreadcrumb(b, hint))
        .whereType<Breadcrumb>()
        .toList()
    // Nothing in the app sets these; cleared so nothing can.
    // ignore: deprecated_member_use
    ..extra = null;
  return event;
}

/// Keep a breadcrumb's shape - what kind of thing happened, and when - and
/// drop anything in it that could be content.
/// String data that is kept on a breadcrumb, by category. Everything else in
/// `data` that is a string is dropped, because for this app a string is often
/// a clip. These are enum names Sentry's own breadcrumbs carry, and without
/// them the breadcrumb says nothing: `state` is resumed / inactive / hidden /
/// paused, `action` is LOW_MEMORY.
const _vocabularyData = <String, Set<String>>{
  'app.lifecycle': {'state'},
  'device.event': {'action'},
};

final _identifier = RegExp(r'^[A-Za-z_]{1,32}$');

bool _isVocabulary(String? category, String key, Object? value) =>
    (_vocabularyData[category]?.contains(key) ?? false) &&
    value is String &&
    _identifier.hasMatch(value);

/// Record what the app was doing, for the next crash or hang report to carry.
///
/// Counts and sizes only, never content: [message] is a fixed description
/// and [data] holds numbers. It goes through [scrubBreadcrumb] regardless, and
/// does nothing where crash reporting is off (debug builds, tests).
void recordDiagnostic(
  String category,
  String message, {
  Map<String, num>? data,
}) {
  Sentry.addBreadcrumb(
    Breadcrumb(category: category, message: message, data: data),
  );
}

@visibleForTesting
Breadcrumb? scrubBreadcrumb(Breadcrumb? crumb, Hint hint) {
  if (crumb == null) return null;
  final data = crumb.data;
  crumb
    ..message = redact(crumb.message)
    ..data = data == null
        ? null
        : {
            for (final entry in data.entries)
              if (entry.value is num || entry.value is bool)
                entry.key: entry.value
              else if (_isVocabulary(crumb.category, entry.key, entry.value))
                entry.key: entry.value
              else if (entry.key == 'url' && entry.value is String)
                'url': redact(entry.value as String)
              else if (entry.key == 'method' && entry.value is String)
                'method': entry.value,
          };
  return crumb;
}
