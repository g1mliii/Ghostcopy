import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghostcopy/services/app_review_service.dart';
import 'package:ghostcopy/services/distribution_consent_service.dart';
import 'package:in_app_review/in_app_review.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Store extends Mock implements InAppReview {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Store store;
  late SharedPreferences prefs;
  late DistributionConsentService consent;
  late DateTime now;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    consent = DistributionConsentService(prefs);
    await consent.accept(
      ageGroup: DistributionAgeGroup.adult,
      guardianAcknowledged: false,
      diagnosticsAllowed: false,
    );
    store = _Store();
    now = DateTime.utc(2026, 11);
    when(store.isAvailable).thenAnswer((_) async => true);
    when(store.requestReview).thenAnswer((_) async {});
    when(
      () => store.openStoreListing(appStoreId: AppReviewService.appStoreId),
    ).thenAnswer((_) async {});
  });

  AppReviewService service({bool supported = true, bool automatic = true}) =>
      AppReviewService(
        prefs,
        store: store,
        now: () => now,
        supported: supported,
        automaticRequestsEnabled: automatic,
      );

  Future<void> reachMilestone(AppReviewService reviews) async {
    await reviews.recordSuccessfulSend();
    now = now.add(const Duration(days: 1));
    await reviews.recordSuccessfulSend();
    now = now.add(const Duration(days: 6));
    await Future.wait(List.generate(8, (_) => reviews.recordSuccessfulSend()));
  }

  test('first use and one-day rapid sends do not request a review', () async {
    final reviews = service();
    await Future.wait(List.generate(15, (_) => reviews.recordSuccessfulSend()));
    await reviews.maybeRequestReview(canPresent: () => true);
    verifyNever(store.requestReview);
    expect(prefs.getInt(AppReviewService.successfulSendsKey), 10);
    now = now.add(const Duration(days: 8));
    await reviews.recordSuccessfulSend();
    await reviews.maybeRequestReview(canPresent: () => true);
    verifyNever(store.requestReview); // Still only two separate usage days.
  });

  test('milestone requests once and cooldown survives a restart', () async {
    final reviews = service();
    await reachMilestone(reviews);
    await Future.wait([
      reviews.maybeRequestReview(canPresent: () => true),
      reviews.maybeRequestReview(canPresent: () => true),
    ]);
    verify(store.requestReview).called(1);
    await service().maybeRequestReview(canPresent: () => true);
    verifyNever(store.requestReview);
    now = now.add(const Duration(days: 120));
    await service().maybeRequestReview(canPresent: () => true);
    verify(store.requestReview).called(1);
  });

  test('navigation during availability check prevents a prompt', () async {
    final reviews = service();
    await reachMilestone(reviews);
    final availability = Completer<bool>();
    when(store.isAvailable).thenAnswer((_) => availability.future);
    var visible = true;
    final attempt = reviews.maybeRequestReview(canPresent: () => visible);
    await Future<void>.delayed(Duration.zero);
    visible = false;
    availability.complete(true);
    await attempt;
    verifyNever(store.requestReview);
    expect(prefs.containsKey(AppReviewService.lastAttemptKey), isFalse);
  });

  test('native failures consume cooldown without opening the store', () async {
    final reviews = service();
    await reachMilestone(reviews);
    when(store.requestReview).thenThrow(PlatformException(code: 'unavailable'));
    await reviews.maybeRequestReview(canPresent: () => true);
    expect(prefs.containsKey(AppReviewService.lastAttemptKey), isTrue);
    verifyNever(
      () => store.openStoreListing(appStoreId: AppReviewService.appStoreId),
    );
    await reviews.maybeRequestReview(canPresent: () => true);
    verify(store.requestReview).called(1);
  });

  test(
    'unavailable native API does not redirect or consume cooldown',
    () async {
      final reviews = service();
      await reachMilestone(reviews);
      when(store.isAvailable).thenAnswer((_) async => false);
      await reviews.maybeRequestReview(canPresent: () => true);
      verifyNever(store.requestReview);
      expect(prefs.containsKey(AppReviewService.lastAttemptKey), isFalse);
    },
  );

  test(
    'manual action opens correct listing even when native API is unavailable',
    () async {
      final reviews = service(automatic: false);
      when(store.isAvailable).thenAnswer((_) async => false);
      expect(await reviews.openStoreReview(), isTrue);
      verify(() => store.openStoreListing(appStoreId: '6811251899')).called(1);
      verifyNever(store.requestReview);
    },
  );

  test('manual store failure is reported without throwing', () async {
    when(
      () => store.openStoreListing(appStoreId: AppReviewService.appStoreId),
    ).thenThrow(PlatformException(code: 'store_missing'));
    expect(await service().openStoreReview(), isFalse);
  });

  test(
    'teen, blocked and unacknowledged users cannot enter review flow',
    () async {
      final reviews = service();
      await reachMilestone(reviews);
      await consent.accept(
        ageGroup: DistributionAgeGroup.teen,
        guardianAcknowledged: true,
        diagnosticsAllowed: false,
      );
      expect(reviews.canReview, isFalse);
      expect(await reviews.openStoreReview(), isFalse);
      await reviews.maybeRequestReview(canPresent: () => true);
      await consent.blockAge();
      expect(reviews.canReview, isFalse);
      await prefs.clear();
      expect(reviews.canReview, isFalse);
      verifyNever(store.isAvailable);
      verifyNever(store.requestReview);
    },
  );

  test('unsupported platforms and debug builds do not auto-prompt', () async {
    final reviews = service(supported: false);
    await reachMilestone(service());
    await reviews.maybeRequestReview(canPresent: () => true);
    expect(await reviews.openStoreReview(), isFalse);
    await service(automatic: false).maybeRequestReview(canPresent: () => true);
    verifyNever(store.isAvailable);
  });
}
