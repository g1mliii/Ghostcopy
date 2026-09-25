import 'package:flutter_test/flutter_test.dart';
import 'package:ghostcopy/services/crash_reporting.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('redact', () {
    test('quoted values - paths, JSON, clip text - are removed', () {
      expect(
        redact("FileSystemException: Cannot open file, path = '/tmp/tax.pdf'"),
        'FileSystemException: Cannot open file, path = [redacted]',
      );
      expect(
        redact('FormatException: Unexpected character "my secret clip"'),
        'FormatException: Unexpected character [redacted]',
      );
    });

    test('database key values are removed', () {
      expect(
        redact('Key (fcm_token)=(abc123) already exists.'),
        'Key (fcm_token)=([redacted]) already exists.',
      );
    });

    test('signed URLs lose their query string', () {
      expect(
        redact(
          'GET https://r2.example.com/u1/file.png?X-Amz-Signature=deadbeef failed',
        ),
        'GET https://r2.example.com/u1/file.png failed',
      );
    });

    test('long text is cut short', () {
      final out = redact('x' * 500)!;
      expect(out.length, lessThanOrEqualTo(201));
      expect(out, endsWith('…'));
    });

    test('null stays null', () => expect(redact(null), isNull));
  });

  test(
    'an event keeps its shape and loses anything that could be a clip',
    () async {
      final event = SentryEvent(
        message: SentryMessage('Could not send "hunter2"'),
        exceptions: [
          SentryException(
            type: 'FormatException',
            value: 'Unexpected character "private clip text"',
          ),
        ],
        breadcrumbs: [
          Breadcrumb(
            message: 'Sent "private clip text"',
            category: 'http',
            data: {
              'url': 'https://x.supabase.co/rest/v1/clipboard?select=*',
              'method': 'POST',
              'status_code': 201,
              'request_body': 'private clip text',
            },
          ),
        ],
      );

      final scrubbed = (await scrubEvent(event, Hint()))!;

      expect(scrubbed.message?.formatted, 'Could not send [redacted]');
      expect(scrubbed.exceptions!.single.type, 'FormatException');
      expect(
        scrubbed.exceptions!.single.value,
        'Unexpected character [redacted]',
      );
      final crumb = scrubbed.breadcrumbs!.single;
      expect(crumb.message, 'Sent [redacted]');
      expect(crumb.data, {
        'url': 'https://x.supabase.co/rest/v1/clipboard',
        'method': 'POST',
        'status_code': 201,
      });
      expect(
        scrubbed.toJson().toString(),
        isNot(contains('private clip text')),
      );
      expect(scrubbed.toJson().toString(), isNot(contains('hunter2')));
    },
  );

  test('crash reporting is configured for errors only, with no content', () {
    final options = SentryFlutterOptions();
    configureCrashReporting(options);

    expect(options.dsn, startsWith('https://'));
    expect(options.sendDefaultPii, isFalse);
    expect(options.attachScreenshot, isFalse);
    expect(options.enablePrintBreadcrumbs, isFalse);
    expect(options.enableUserInteractionBreadcrumbs, isFalse);
    expect(options.enableAutoPerformanceTracing, isFalse);
    expect(options.tracesSampleRate, isNull);
    expect(options.beforeSend, isNotNull);
    expect(options.beforeBreadcrumb, isNotNull);
  });
}
