import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghostcopy/services/hotkey_service.dart';
import 'package:ghostcopy/services/impl/hotkey_service.dart';
import 'package:ghostcopy/ui/widgets/hotkey_capture_field.dart';

/// Regression tests for the global hotkey.
///
/// Changing the shortcut used to unregister the old one and never register the
/// new one, and any key outside a list of seven silently became `S` - so the
/// settings UI displayed a shortcut that was not the one registered, when one
/// was registered at all. Persistence did not exist either: startup always
/// re-registered the hardcoded default.
void main() {
  group('HotKey identity', () {
    test('structurally identical hotkeys are equal', () {
      const a = HotKey(key: 's', ctrl: true, shift: true);
      const b = HotKey(key: 's', ctrl: true, shift: true);

      // Registration is keyed on the hotkey, so two equal descriptions must be
      // the same entry or a re-register leaks the previous OS registration.
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
    });

    test('case does not change identity', () {
      expect(
        const HotKey(key: 'S', ctrl: true),
        const HotKey(key: 's', ctrl: true),
      );
    });

    test('different modifiers are different hotkeys', () {
      expect(
        const HotKey(key: 's', ctrl: true),
        isNot(const HotKey(key: 's', ctrl: true, shift: true)),
      );
    });
  });

  group('storage round-trip', () {
    test('survives encode then decode', () {
      const original = HotKey(key: 'k', ctrl: true, shift: true, alt: true);
      expect(HotKey.fromStorageString(original.toStorageString()), original);
    });

    test('modifier order is stable', () {
      expect(
        const HotKey(key: 'j', meta: true, ctrl: true).toStorageString(),
        'ctrl+meta+j',
      );
    });

    test('null and empty decode to null rather than a wrong hotkey', () {
      expect(HotKey.fromStorageString(null), isNull);
      expect(HotKey.fromStorageString(''), isNull);
    });

    test('an unknown modifier is rejected, not read as the key', () {
      expect(HotKey.fromStorageString('hyper+s'), isNull);
    });
  });

  group('key mapping', () {
    test('maps every letter to its own physical key', () {
      final mapped = <PhysicalKeyboardKey>{};
      for (final c in 'abcdefghijklmnopqrstuvwxyz'.split('')) {
        final key = HotkeyService.convertKey(c);
        expect(key, isNotNull, reason: '"$c" should be mappable');
        mapped.add(key!);
      }
      // 26 distinct keys: the old switch collapsed 22 of them onto keyS.
      expect(mapped.length, 26);
    });

    test('maps digits and named keys', () {
      expect(HotkeyService.convertKey('7'), PhysicalKeyboardKey.digit7);
      expect(HotkeyService.convertKey('f5'), PhysicalKeyboardKey.f5);
      expect(HotkeyService.convertKey('space'), PhysicalKeyboardKey.space);
    });

    test('is case insensitive', () {
      expect(HotkeyService.convertKey('K'), PhysicalKeyboardKey.keyK);
    });

    test('returns null for an unmappable key instead of defaulting to S', () {
      for (final key in ['', 'nonsense', 'f99', '§']) {
        expect(
          HotkeyService.convertKey(key),
          isNull,
          reason: '"$key" must be refused, not silently registered as S',
        );
      }
    });
  });

  group('capture field and service agree', () {
    // The field used to accept anything whose keyLabel was one character,
    // which is a different set from what convertKey can register. Space fell
    // through the gap in the worst way: its label IS one character, a literal
    // " ", so the field accepted it and produced a hotkey the service then
    // refused - and since Option+Space is the macOS default, a user who
    // changed their shortcut could not restore it.
    test('space is captured as a registerable key', () {
      final stored = HotkeyCapture.storedKeyFor(LogicalKeyboardKey.space);

      expect(stored, equals('space'));
      expect(HotkeyService.convertKey(stored!), isNotNull);
    });

    test('a raw space label is still refused by the service', () {
      // Proves the normalization is load-bearing rather than cosmetic: the
      // value the field produced before is genuinely unregisterable.
      expect(HotkeyService.convertKey(' '), isNull);
    });

    test('every named key the field emits can be registered', () {
      // The invariant: the field must never hand the service a key it will
      // reject. Adding a key to the field's map without adding it to
      // convertKey fails here rather than at the moment a user presses it.
      const named = <LogicalKeyboardKey>[
        LogicalKeyboardKey.space,
        LogicalKeyboardKey.delete,
        LogicalKeyboardKey.insert,
        LogicalKeyboardKey.home,
        LogicalKeyboardKey.end,
        LogicalKeyboardKey.pageUp,
        LogicalKeyboardKey.pageDown,
        LogicalKeyboardKey.arrowUp,
        LogicalKeyboardKey.arrowDown,
        LogicalKeyboardKey.arrowLeft,
        LogicalKeyboardKey.arrowRight,
        LogicalKeyboardKey.f1,
        LogicalKeyboardKey.f5,
        LogicalKeyboardKey.f12,
      ];

      for (final key in named) {
        final stored = HotkeyCapture.storedKeyFor(key);
        expect(stored, isNotNull, reason: '${key.debugName} is not mapped');
        expect(
          HotkeyService.convertKey(stored!),
          isNotNull,
          reason: '${key.debugName} maps to "$stored", which cannot register',
        );
      }
    });

    test('keys that are poor global shortcuts stay unmapped', () {
      // Capturing these would fight the way the field is operated.
      for (final key in [
        LogicalKeyboardKey.enter,
        LogicalKeyboardKey.tab,
        LogicalKeyboardKey.escape,
        LogicalKeyboardKey.backspace,
      ]) {
        expect(
          HotkeyCapture.storedKeyFor(key),
          isNull,
          reason: '${key.debugName} should not be capturable',
        );
      }
    });

    test('the default macOS hotkey survives a storage round-trip', () {
      // The end-to-end shape of the bug: capture it, store it, read it back,
      // register it.
      const captured = HotKey(key: 'space', alt: true);

      final restored = HotKey.fromStorageString(captured.toStorageString());

      expect(restored, equals(captured));
      expect(HotkeyService.convertKey(restored!.key), isNotNull);
    });
  });
}
