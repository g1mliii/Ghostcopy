import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/device.dart';
import '../utils/serial_queue.dart';

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

  /// Bumped by every [clear]. A fetch captures it before going out and hands
  /// it to [save], so a fetch still in flight at sign-out cannot write the
  /// signed-out account's list back after the clear.
  static int get generation => _generation;
  static int _generation = 0;

  /// Saves and clears run one at a time, in the order asked for, so a save
  /// cannot be overtaken by the clear meant to follow it either.
  static final _queue = SerialQueue();

  /// The list saved for [userId], or empty when there is none.
  static Future<List<Device>> load(String userId) async {
    // Behind any save or clear already queued, as HistoryDiskCache.load is.
    await _queue.idle;
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

  /// Replace the list saved for [userId] with [devices], unless the list
  /// has been cleared since [generation] was read.
  static Future<void> save(
    String userId,
    List<Device> devices, {
    required int generation,
  }) => _queue.run(() async {
    if (generation != _generation) return;
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
  });

  static Future<void> clear() {
    _generation++;
    return _queue.run(() async {
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.remove(_key);
      } on Object catch (e) {
        debugPrint('[SavedDeviceList] Not cleared: $e');
      }
    });
  }
}
