import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:in_app_review/in_app_review.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../app_review_service.dart';
import '../distribution_consent_service.dart';

/// Uses the stores' unmodified review UI. A completed request does not mean
/// that a prompt appeared, a rating was chosen, or a review was submitted.
class AppReviewService implements IAppReviewService {
  AppReviewService(
    this._preferences, {
    InAppReview? store,
    IDistributionConsentService? consent,
    DateTime Function()? now,
    bool? supported,
    bool? automaticRequestsEnabled,
  }) : _store = store ?? InAppReview.instance,
       _consent = consent ?? DistributionConsentService(_preferences),
       _now = now ?? DateTime.now,
       _supported = supported ?? (Platform.isAndroid || Platform.isIOS),
       _automaticRequestsEnabled = automaticRequestsEnabled ?? kReleaseMode;

  static const appStoreId = '6811251899';
  static const firstSuccessKey = 'review_first_success_at';
  static const successfulSendsKey = 'review_successful_sends';
  static const activeDaysKey = 'review_active_days';
  static const lastAttemptKey = 'review_last_attempt_at';

  final SharedPreferences _preferences;
  final InAppReview _store;
  final IDistributionConsentService _consent;
  final DateTime Function() _now;
  final bool _supported;
  final bool _automaticRequestsEnabled;
  Future<void> _recording = Future<void>.value();
  bool _requesting = false;

  @override
  bool get canReview =>
      _supported &&
      _consent.isAccepted &&
      _consent.ageGroup == DistributionAgeGroup.adult;

  DateTime? _date(String key) {
    final value = _preferences.get(key);
    return value is String ? DateTime.tryParse(value)?.toUtc() : null;
  }

  @override
  Future<void> recordSuccessfulSend() {
    // Serialize rapid sends so asynchronous writes cannot lose a count.
    return _recording = _recording.then((_) async {
      if (!canReview) return;
      try {
        final now = _now().toUtc();
        if (_date(firstSuccessKey) == null) {
          await _preferences.setString(firstSuccessKey, now.toIso8601String());
        }
        final count = _preferences.getInt(successfulSendsKey) ?? 0;
        await _preferences.setInt(
          successfulSendsKey,
          count < 10 ? count + 1 : 10,
        );
        final days = _preferences.getStringList(activeDaysKey) ?? [];
        final today = now.toIso8601String().substring(0, 10);
        if (days.length < 3 && !days.contains(today)) {
          await _preferences.setStringList(activeDaysKey, [...days, today]);
        }
      } on Exception {
        debugPrint('[AppReview] Could not record usage milestone');
      }
    });
  }

  @override
  Future<void> maybeRequestReview({required bool Function() canPresent}) async {
    if (_requesting || !_automaticRequestsEnabled || !canReview) return;
    _requesting = true;
    try {
      await _recording;
      final now = _now().toUtc();
      final first = _date(firstSuccessKey);
      final last = _date(lastAttemptKey);
      if (first == null ||
          now.difference(first) < const Duration(days: 7) ||
          (_preferences.getInt(successfulSendsKey) ?? 0) < 10 ||
          (_preferences.getStringList(activeDaysKey)?.length ?? 0) < 3 ||
          (last != null && now.difference(last) < const Duration(days: 120)) ||
          !canPresent() ||
          !await _store.isAvailable()) {
        return;
      }
      if (!canReview || !canPresent()) return;
      // Consume our cooldown before requesting. Stores can silently suppress
      // the dialog; never infer that it was displayed or retry it immediately.
      if (!await _preferences.setString(
        lastAttemptKey,
        now.toIso8601String(),
      )) {
        return;
      }
      if (!canReview || !canPresent()) return;
      await _store.requestReview();
    } on Exception {
      debugPrint('[AppReview] Native review request unavailable');
    } finally {
      _requesting = false;
    }
  }

  @override
  Future<bool> openStoreReview() async {
    if (!canReview) return false;
    try {
      await _preferences.setString(
        lastAttemptKey,
        _now().toUtc().toIso8601String(),
      );
      await _store.openStoreListing(appStoreId: appStoreId);
      return true;
    } on Exception {
      debugPrint('[AppReview] Could not open store review page');
      return false;
    }
  }
}
