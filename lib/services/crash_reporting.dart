import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

/// The GhostCopy Sentry project (spiderweb/flutter). A DSN only lets a client
/// submit events - it grants no read access - so, like the Supabase
/// publishable key in main.dart, it is compiled in rather than hidden.
const _sentryDsn =
    'https://e0c0077d7dadc346ef2e6b41d508f583@o4511233616969728.ingest.us.sentry.io/4512145211392000';

/// Run the app with crash reporting, in release builds only.
///
/// Debug and profile builds run [app] directly: their errors are for the
/// developer's console, not the project's issue list.
Future<void> runWithCrashReporting(FutureOr<void> Function() app) async {
  if (!kReleaseMode) {
    await app();
    return;
  }
  await SentryFlutter.init(configureCrashReporting, appRunner: app);
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
    // Errors only. Performance was profiled directly (docs/*-performance.md),
    // and tracing costs CPU on an app that must idle at zero.
    ..enableAutoPerformanceTracing = false
    ..enableUserInteractionTracing = false
    ..enableFramesTracking = false
    ..tracesSampleRate = null
    // Kept at their defaults: app-hang (iOS, macOS) and ANR (Android) reports,
    // and session tracking for the crash-free rate. Declared on the App Store
    // as Performance Data and Other Diagnostic Data, not linked to the user.
    ..maxBreadcrumbs = 40
    ..beforeSend = scrubEvent
    ..beforeBreadcrumb = scrubBreadcrumb;
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
@visibleForTesting
String? redact(String? text) {
  if (text == null) return null;
  var out = text
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
              else if (entry.key == 'url' && entry.value is String)
                'url': redact(entry.value as String)
              else if (entry.key == 'method' && entry.value is String)
                'method': entry.value,
          };
  return crumb;
}
