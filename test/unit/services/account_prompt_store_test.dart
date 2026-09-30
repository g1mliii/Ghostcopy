import 'package:flutter_test/flutter_test.dart';
import 'package:ghostcopy/services/account_prompt_store.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

User _user(String id, {required bool anonymous}) => User(
  id: id,
  appMetadata: const {},
  userMetadata: const {},
  aud: 'authenticated',
  createdAt: '2026-01-01T00:00:00Z',
  isAnonymous: anonymous,
);

void main() {
  group('canSkipMobileWelcome', () {
    test('no session shows the welcome screen', () {
      expect(canSkipMobileWelcome(null, linkedGuestUserId: 'g'), isFalse);
    });

    test('a signed-in account skips it', () {
      expect(
        canSkipMobileWelcome(
          _user('u', anonymous: false),
          linkedGuestUserId: null,
        ),
        isTrue,
      );
    });

    test('the guest this phone was linked into by QR skips it', () {
      expect(
        canSkipMobileWelcome(
          _user('desktop-guest', anonymous: true),
          linkedGuestUserId: 'desktop-guest',
        ),
        isTrue,
      );
    });

    test('any other guest - the one sign-out leaves - does not', () {
      expect(
        canSkipMobileWelcome(
          _user('fresh-guest', anonymous: true),
          linkedGuestUserId: 'desktop-guest',
        ),
        isFalse,
      );
      expect(
        canSkipMobileWelcome(
          _user('fresh-guest', anonymous: true),
          linkedGuestUserId: null,
        ),
        isFalse,
      );
    });
  });

  test('the linked guest survives a relaunch', () async {
    SharedPreferences.setMockInitialValues({});
    await (await AccountPromptStore.open()).rememberLinkedGuest('g');

    final reopened = await AccountPromptStore.open();
    expect(reopened.linkedGuestUserId, 'g');
  });

  test('the first send is remembered across launches', () async {
    SharedPreferences.setMockInitialValues({});
    final store = await AccountPromptStore.open();
    expect(store.hasSent, isFalse);

    await store.recordSend();

    expect((await AccountPromptStore.open()).hasSent, isTrue);
  });
}
