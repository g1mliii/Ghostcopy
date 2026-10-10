import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghostcopy/services/impl/linux_clipboard_reader.dart';

void main() {
  LinuxClipboardReader readerFor(Map<String, List<int>> offers) =>
      LinuxClipboardReader(
        paste: (args) async {
          if (args.singleOrNull == '--list-types') {
            return Uint8List.fromList(utf8.encode(offers.keys.join('\n')));
          }
          expect(args.take(2), ['--no-newline', '--type']);
          return Uint8List.fromList(offers[args.last]!);
        },
      );

  test('preserves trailing newlines and Unicode without a shell', () async {
    const value = 'hello \$HOME; `command` 🙂\n\n';
    final result = await readerFor({'text/plain': utf8.encode(value)}).read();
    expect(result.text, value);
  });

  test('PNG bytes take priority over a text alternative', () async {
    final result = await readerFor({
      'image/png': [137, 80, 78, 71, 0, 255],
      'text/plain': utf8.encode('image description'),
    }).read();
    expect(result.imageBytes, [137, 80, 78, 71, 0, 255]);
    expect(result.mimeType, 'image/png');
  });

  test('HTML-only selection stays available', () async {
    final result = await readerFor({
      'text/html': utf8.encode('<b>Hello</b>'),
    }).read();
    expect(result.html, '<b>Hello</b>');
  });

  test('password-manager offers are not imported', () async {
    final result = await readerFor({
      'x-kde-passwordManagerHint': utf8.encode('secret'),
      'text/plain': utf8.encode('never sync me'),
    }).read();
    expect(result.isEmpty, isTrue);
    expect(result.readFailed, isFalse);
  });

  test('remote URI is never opened as a file', () async {
    final result = await readerFor({
      'text/uri-list': utf8.encode(
        'file://remote-server/shared/secret.txt\r\n',
      ),
    }).read();
    expect(result.isEmpty, isTrue);
  });

  test('missing helper is a retryable read failure', () async {
    final reader = LinuxClipboardReader(
      paste: (_) async {
        throw const ProcessException('wl-paste', [], 'not installed');
      },
    );
    final result = await reader.read();
    expect(result.readFailed, isTrue);
  });

  test(
    'streaming size limit rejects the chunk that crosses the limit',
    () async {
      await expectLater(
        LinuxClipboardReader.readBounded(
          Stream.fromIterable([
            [1, 2],
            [3, 4],
          ]),
          limit: 3,
        ),
        throwsFormatException,
      );
      expect(
        await LinuxClipboardReader.readBounded(
          Stream.fromIterable([
            [1, 2],
            [3],
          ]),
          limit: 3,
        ),
        [1, 2, 3],
      );
    },
  );
}
