import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

/// Where this install's id is kept.
const String installIdKey = 'ghostcopy_device_install_id';

/// This install's random id, created the first time it is asked for: a
/// device id where the platform gives none.
Future<String> getOrCreateInstallId([SharedPreferences? preferences]) async {
  final prefs = preferences ?? await SharedPreferences.getInstance();
  final existing = prefs.getString(installIdKey);
  if (existing != null && existing.length >= 8) return existing;

  final random = Random.secure();
  final generated = List<int>.generate(
    16,
    (_) => random.nextInt(256),
  ).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
  await prefs.setString(installIdKey, generated);
  return generated;
}
