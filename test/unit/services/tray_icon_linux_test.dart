import 'package:flutter_test/flutter_test.dart';
import 'package:ghostcopy/services/impl/tray_service.dart';

/// The Linux tray ghost is monochrome, and Plasma never recolours a file-path
/// tray icon, so the ink is chosen from the panel's colour scheme. Picking the
/// wrong one leaves a white ghost on a white panel - an invisible icon.
void main() {
  const white = 'assets/icons/tray_icon_linux.png';
  const dark = 'assets/icons/tray_icon_linux_light_panel.png';

  test('Breeze Dark gets the white ghost', () {
    const kdeglobals = '''
[Colors:Header]
BackgroundNormal=239,240,241

[Colors:Window]
BackgroundAlternate=41,44,48
BackgroundNormal=32,35,38
''';
    expect(TrayService.linuxTrayIconFor(kdeglobals), white);
  });

  test('Breeze light gets the dark ghost', () {
    const kdeglobals = '''
[Colors:Window]
BackgroundNormal=239,240,241
''';
    expect(TrayService.linuxTrayIconFor(kdeglobals), dark);
  });

  test('reads only the Window group, not a light Header', () {
    const kdeglobals = '''
[Colors:Window]
ForegroundNormal=252,252,252

[Colors:Header]
BackgroundNormal=239,240,241
''';
    expect(TrayService.linuxTrayIconFor(kdeglobals), white);
  });

  test('falls back to white without KDE or with a malformed colour', () {
    expect(TrayService.linuxTrayIconFor(null), white);
    expect(TrayService.linuxTrayIconFor(''), white);
    expect(
      TrayService.linuxTrayIconFor('[Colors:Window]\nBackgroundNormal=oops\n'),
      white,
    );
  });
}
