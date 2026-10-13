import 'package:flutter_test/flutter_test.dart';
import 'package:ghostcopy/services/hotkey_service.dart';
import 'package:ghostcopy/services/impl/linux_hotkey_service.dart';

void main() {
  test('encodes XDG modifier names and keysyms', () {
    expect(
      LinuxHotkeyService.preferredTrigger(
        const HotKey(key: 's', ctrl: true, shift: true),
      ),
      'CTRL+SHIFT+s',
    );
    expect(
      LinuxHotkeyService.preferredTrigger(
        const HotKey(key: 'enter', meta: true),
      ),
      'LOGO+Return',
    );
    expect(
      LinuxHotkeyService.preferredTrigger(const HotKey(key: 'f12', alt: true)),
      'ALT+F12',
    );
    expect(
      () => LinuxHotkeyService.preferredTrigger(const HotKey(key: 'unknown')),
      throwsA(isA<UnsupportedHotkeyException>()),
    );
  });
}
