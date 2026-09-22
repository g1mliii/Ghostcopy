import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghostcopy/services/obsidian_service.dart';

void main() {
  test('quoted vault paths append to the existing folder', () async {
    final vault = await Directory.systemTemp.createTemp('obsidian vault ');
    addTearDown(() => vault.delete(recursive: true));
    for (final quote in ["'", '"']) {
      await ObsidianService().appendToVault(
        vaultPath: '$quote${vault.path}$quote',
        fileName: 'clipboard.md',
        content: 'integration test\n\n  indented text',
        deviceType: 'macos',
        direction: 'received',
      );
    }
    final note = await File('${vault.path}/clipboard.md').readAsString();
    expect('integration test'.allMatches(note), hasLength(2));
    expect('*Received from macOS*'.allMatches(note), hasLength(2));
    expect(note, contains('integration test\n\n  indented text'));
    expect(note, startsWith('\n### '));
    expect(note, endsWith('\n\n---\n'));
  });

  test('missing vault is rejected without creating a new directory', () async {
    final root = await Directory.systemTemp.createTemp('obsidian-test');
    addTearDown(() => root.delete(recursive: true));
    final missing = '${root.path}/missing';
    await expectLater(
      ObsidianService().appendToVault(
        vaultPath: missing,
        fileName: 'clipboard.md',
        content: 'test',
      ),
      throwsA(isA<FileSystemException>()),
    );
    expect(Directory(missing).existsSync(), isFalse);
  });
}
