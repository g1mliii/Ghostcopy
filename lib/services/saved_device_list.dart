import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/device.dart';

/// The last device list fetched for an account, kept between launches so the
/// send-target chips can be drawn before the network answers.
///
/// Without it every cold start sat on a spinner where the chips go until the
/// devices query came back - a second or more on a phone waking its radio -
/// for a list that changes a few times a year. The saved copy is shown first
/// and replaced by the fetched one as soon as it lands, so a device added or
/// renamed elsewhere still appears; it is just no longer what the screen waits
/// on.
///
/// Small and not secret: names and platforms, owned by one account. Push
/// tokens are left out - they belong to other devices and nothing drawn from
/// this list needs them. The owner's id is stored with the list and checked on
/// every read, and auth clears it on sign-out, so another account never sees
/// it.
///
/// Every failure reads as "nothing saved": without this the app behaves as it
/// did before, which is the worst case.
class SavedDeviceList {
  SavedDeviceList._();

  static const String _key = 'saved_device_list';

  /// Bumped if the stored shape changes; an unknown version reads as empty.
  static const int _version = 1;

  /// The list saved for [userId], or empty when there is none.
  static Future<List<Device>> load(String userId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key);
      if (raw == null) return const [];
      final saved = jsonDecode(raw) as Map<String, dynamic>;
      if (saved['v'] != _version || saved['user'] != userId) return const [];
      return (saved['devices'] as List)
          .map((json) => Device.fromJson(json as Map<String, dynamic>))
          .toList();
    } on Object catch (e) {
      debugPrint('[SavedDeviceList] Not read: $e');
      return const [];
    }
  }

  /// Replace the list saved for [userId] with [devices].
  static Future<void> save(String userId, List<Device> devices) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _key,
        jsonEncode({
          'v': _version,
          'user': userId,
          'devices': [
            for (final device in devices) device.toJson()..remove('fcm_token'),
          ],
        }),
      );
    } on Object catch (e) {
      debugPrint('[SavedDeviceList] Not saved: $e');
    }
  }

  static Future<void> clear() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_key);
    } on Object catch (e) {
      debugPrint('[SavedDeviceList] Not cleared: $e');
    }
  }
}
