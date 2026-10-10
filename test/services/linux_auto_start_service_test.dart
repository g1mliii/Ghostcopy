import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghostcopy/services/impl/linux_auto_start_service.dart';
import 'package:path/path.dart' as path;

void main() {
  test('startup enable/disable uses the supplied XDG directory', () async {
    final directory = Directory.systemTemp.createTempSync('ghostcopy-startup-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final service = LinuxAutoStartService(
      configDirectory: directory.path,
      executable: '/home/test user/.local/lib/ghostcopy/ghostcopy',
    );
    expect(await service.isEnabled(), isFalse);
    await service.enable();
    final contents = File(
      path.join(directory.path, 'autostart', 'ghostcopy.desktop'),
    ).readAsStringSync();
    expect(
      contents,
      contains(
        'Exec="/home/test user/.local/lib/ghostcopy/ghostcopy" --launched-at-startup',
      ),
    );
    expect(await service.isEnabled(), isTrue);
    await service.enable(); // Replacing an existing entry remains valid.
    await service.disable();
    expect(await service.isEnabled(), isFalse);
  });

  test('Exec escaping handles reserved characters and field codes', () {
    expect(
      LinuxAutoStartService.quoteExec('/a%u b/ghostcopy'),
      '"/a%%u b/ghostcopy"',
    );
    expect(
      LinuxAutoStartService.quoteExec(r'/a$b/ghostcopy'),
      r'"/a\\$b/ghostcopy"',
    );
    expect(
      () => LinuxAutoStartService.quoteExec('/a\nb'),
      throwsFormatException,
    );
  });
}
