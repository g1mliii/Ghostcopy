import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghostcopy/services/temp_file_service.dart';

void main() {
  late Directory root;
  late TempFileService service;
  Uri? clipboardFile;
  var clipboardUnavailable = false;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('ghostcopy_retention_test');
    clipboardFile = null;
    clipboardUnavailable = false;
    service = TempFileService(
      temporaryDirectory: () async => root,
      clipboardFile: () async {
        if (clipboardUnavailable) throw Exception('Clipboard unavailable');
        return clipboardFile;
      },
      earlierTemporaryDirectory: () => null,
    );
  });

  // A Store install moves its temp files into the package; an earlier
  // version's - decrypted downloads - are cleaned by the same rules, the one
  // the clipboard still points at kept.
  test(
    "cleans an earlier version's temp folder, keeping the active file",
    () async {
      final earlier = await Directory.systemTemp.createTemp(
        'ghostcopy_earlier',
      );
      addTearDown(() => earlier.delete(recursive: true));
      final old = DateTime.now().subtract(const Duration(hours: 2));
      final stale = File('${earlier.path}/ghostcopy_1_notes.txt')
        ..writeAsStringSync('plaintext');
      final active = File('${earlier.path}/ghostcopy_2_photo.png')
        ..writeAsStringSync('on the clipboard');
      final other = File('${earlier.path}/other_app.tmp')
        ..writeAsStringSync('x');
      for (final file in [stale, active, other]) {
        await file.setLastModified(old);
      }
      clipboardFile = active.uri;
      final packaged = TempFileService(
        temporaryDirectory: () async => root,
        clipboardFile: () async => clipboardFile,
        earlierTemporaryDirectory: () => earlier,
      );

      await packaged.cleanupTempFiles();

      expect(stale.existsSync(), isFalse);
      expect(active.existsSync(), isTrue);
      expect(other.existsSync(), isTrue);
    },
  );

  tearDown(() async {
    service.stopPeriodicCleanup();
    await root.delete(recursive: true);
  });

  test(
    'retains the active file past the cleanup cutoff, then removes it after replacement',
    () async {
      final file = await service.saveTempFile(
        Uint8List.fromList([1, 2, 3]),
        'report.pdf',
      );
      await file.setLastModified(
        DateTime.now().subtract(const Duration(hours: 2)),
      );
      clipboardFile = file.uri;
      await service.cleanupTempFiles();
      expect(file.existsSync(), isTrue);
      clipboardFile = null;
      await service.cleanupTempFiles();
      expect(file.existsSync(), isFalse);
    },
  );

  test('same-name copies have distinct backing files', () async {
    final first = await service.saveTempFile(
      Uint8List.fromList([1]),
      'report.pdf',
    );
    final second = await service.saveTempFile(
      Uint8List.fromList([2]),
      'report.pdf',
    );
    expect(first.path, isNot(second.path));
    expect(await first.readAsBytes(), [1]);
    expect(await second.readAsBytes(), [2]);
  });

  test(
    'retains files when the active clipboard cannot be determined',
    () async {
      final file = await service.saveTempFile(
        Uint8List.fromList([1]),
        'report.pdf',
      );
      await file.setLastModified(
        DateTime.now().subtract(const Duration(hours: 2)),
      );
      clipboardUnavailable = true;
      await service.cleanupTempFiles();
      expect(file.existsSync(), isTrue);
    },
  );
}
