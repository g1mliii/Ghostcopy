import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// What the app remembers about guest accounts between launches: which guest
/// a phone was linked into by QR, and when a desktop last asked its guest to
/// make an account.
///
/// Not part of ISettingsService: nothing here is a preference the user sets,
/// and none of it belongs in a settings screen.
class AccountPromptStore {
  AccountPromptStore(this._prefs, {DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  static Future<AccountPromptStore> open() async =>
      AccountPromptStore(await SharedPreferences.getInstance());

  /// How long "Not now" keeps the account offer away.
  static const Duration snooze = Duration(days: 7);

  static const String _keyLinkedGuest = 'qr_linked_guest_user_id';
  static const String _keyHasSent = 'account_offer_has_sent';
  static const String _keySnoozedUntil = 'account_offer_snoozed_until';

  final SharedPreferences _prefs;
  final DateTime Function() _clock;

  // ========== PHONE LINKED BY QR ==========

  /// The guest account this phone joined by scanning a desktop's QR code.
  String? get linkedGuestUserId => _prefs.getString(_keyLinkedGuest);

  Future<void> rememberLinkedGuest(String userId) =>
      _prefs.setString(_keyLinkedGuest, userId);

  // ========== DESKTOP ACCOUNT OFFER ==========

  /// Whether this install has ever sent a clip. The offer waits for that, so
  /// it comes after the app has shown what it does rather than before.
  bool get hasSent => _prefs.getBool(_keyHasSent) ?? false;

  Future<void> recordSend() async {
    if (!hasSent) await _prefs.setBool(_keyHasSent, true);
  }

  bool get isOfferSnoozed {
    final until = _prefs.getInt(_keySnoozedUntil);
    return until != null && _clock().millisecondsSinceEpoch < until;
  }

  Future<void> snoozeOffer() => _prefs.setInt(
    _keySnoozedUntil,
    _clock().add(snooze).millisecondsSinceEpoch,
  );
}

/// Whether a phone launching with [user] goes straight to the main screen.
///
/// A signed-in account does. So does the guest this phone was linked into by
/// QR: that session is the desktop's, already paired and receiving clips, and
/// sending it back through the welcome screen on every cold launch made the
/// user scan again for nothing. Any other guest - the fresh one that sign-out
/// and account deletion leave behind - still sees the welcome screen, because
/// on its own it is an empty account nothing sends to.
bool canSkipMobileWelcome(User? user, {required String? linkedGuestUserId}) {
  if (user == null) return false;
  if (!user.isAnonymous) return true;
  return user.id == linkedGuestUserId;
}
