import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghostcopy/utils/windows_registry.dart';

void main() {
  test('nonzero reg.exe exit status is reported as failure', () async {
    await expectLater(
      runWindowsRegistryCommand([
        'add',
        r'HKCU\Software\GhostCopyTest',
      ], run: (exe, args) async => ProcessResult(1, 1, '', 'Access denied')),
      throwsA(isA<ProcessException>()),
    );
  });

  test(
    'registry command preserves spaced paths and percent placeholders',
    () async {
      final args = [
        'add',
        r'HKCU\Software\Classes\*\shell\GhostCopySend\command',
        '/ve',
        '/d',
        r'"C:\Program Files\GhostCopy\ghostcopy.exe" --send-file "%1"',
        '/f',
      ];
      await runWindowsRegistryCommand(
        args,
        run: (exe, actual) async {
          expect(exe, 'reg');
          expect(actual, args);
          return ProcessResult(1, 0, 'Success', '');
        },
      );
    },
  );
}
