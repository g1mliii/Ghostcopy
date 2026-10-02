import 'package:flutter_test/flutter_test.dart';
import 'package:ghostcopy/services/impl/window_service.dart';

// The tray click on an ordinary pin reads this to tell a window that was in
// front (lost focus to the click just now) from one covered by another app
// (lost focus earlier).
void main() {
  test('no blur yet is not a recent one', () {
    expect(
      WindowService().blurredWithin(const Duration(milliseconds: 500)),
      isFalse,
    );
  });

  test('a blur just now is recent, and stops being', () async {
    final window = WindowService()..noteBlur();
    expect(window.blurredWithin(const Duration(milliseconds: 500)), isTrue);

    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(window.blurredWithin(const Duration(milliseconds: 10)), isFalse);
  });
}
