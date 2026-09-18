import 'package:flutter_test/flutter_test.dart';
import 'package:ghostcopy/repositories/impl/clipboard_repository.dart';
import 'package:ghostcopy/utils/device_selection.dart';

/// Regression tests for toggling an auto-send destination.
///
/// This logic existed three times and the copies drifted. The damaging one:
/// an empty set is the all-devices sentinel and every chip renders selected
/// because of it, so a toggle that does not expand the sentinel first ADDS
/// the tapped device instead of removing it - leaving it as the only target
/// and silently cutting off every other destination.
void main() {
  const all = ClipboardRepository.validDeviceTypes;

  Set<String>? toggle(Set<String> current, String device) =>
      nextDeviceSelection(
        current: current,
        allDeviceTypes: all,
        toggled: device,
      );

  group('toggling from the all-devices sentinel', () {
    test('excludes the tapped device rather than isolating it', () {
      // The bug: this returned {windows}, making Windows the ONLY target.
      final result = toggle({}, 'windows');

      expect(result, isNotNull);
      expect(result, isNot(contains('windows')));
      expect(result, containsAll(all.where((d) => d != 'windows')));
    });

    test('every device behaves the same way', () {
      for (final device in all) {
        final result = toggle({}, device);

        expect(result, isNotNull, reason: 'toggling $device was refused');
        expect(
          result,
          isNot(contains(device)),
          reason: '$device should have been excluded, not isolated',
        );
        expect(result, hasLength(all.length - 1));
      }
    });
  });

  group('emptying the selection', () {
    test('the last remaining device cannot be turned off', () {
      // Storing {} would mean "all devices", so turning the last one off
      // would have turned all of them back on.
      expect(toggle({'macos'}, 'macos'), isNull);
    });

    test('turning off the second to last is still allowed', () {
      expect(toggle({'macos', 'ios'}, 'ios'), equals({'macos'}));
    });
  });

  group('normalization', () {
    test('selecting the final missing device folds back to the sentinel', () {
      final allButOne = all.where((d) => d != 'linux').toSet();

      // One stored representation of "everywhere", so a platform added in a
      // later release is still covered by an existing preference.
      expect(toggle(allButOne, 'linux'), isEmpty);
    });

    test('a partial selection is stored verbatim', () {
      expect(toggle({'windows', 'macos'}, 'ios'), {'windows', 'macos', 'ios'});
    });
  });

  test('two toggles compose, rather than each starting from the sentinel', () {
    // The race the call sites fixed by updating local state before persisting:
    // if the second toggle read the pre-toggle value it would discard the
    // first. Composing them here is what that ordering guarantees.
    final first = toggle({}, 'windows');
    final second = toggle(first!, 'ios');

    expect(second, isNot(contains('windows')));
    expect(second, isNot(contains('ios')));
  });
}
