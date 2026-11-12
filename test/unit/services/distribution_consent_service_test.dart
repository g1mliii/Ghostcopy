import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghostcopy/services/distribution_consent_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<DistributionConsentService> service() async =>
      DistributionConsentService(
        await SharedPreferences.getInstance(),
        now: () => DateTime.utc(2026, 11, 12, 12),
      );

  test('missing receipt disables cloud eligibility and diagnostics', () async {
    final consent = await service();
    expect(consent.isAccepted, isFalse);
    expect(consent.diagnosticsAllowed, isFalse);
  });

  test('underage and unacknowledged teen cannot create a receipt', () async {
    final consent = await service();
    for (final age in [
      DistributionAgeGroup.under16,
      DistributionAgeGroup.teen,
    ]) {
      await expectLater(
        consent.accept(
          ageGroup: age,
          guardianAcknowledged: false,
          diagnosticsAllowed: true,
        ),
        throwsException,
      );
    }
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.containsKey(IDistributionConsentService.receiptKey), isFalse);
  });

  test('adult receipt survives reload without enabling diagnostics', () async {
    final consent = await service();
    await consent.accept(
      ageGroup: DistributionAgeGroup.adult,
      guardianAcknowledged: false,
      diagnosticsAllowed: false,
    );
    final restored = DistributionConsentService(await loadConsentPreferences());
    expect(restored.isAccepted, isTrue);
    expect(restored.diagnosticsAllowed, isFalse);
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(IDistributionConsentService.receiptKey)!;
    final receipt = jsonDecode(raw) as Map<String, Object?>;
    expect(receipt['acceptedAt'], '2026-11-12T12:00:00.000Z');
    expect(receipt['verificationMethod'], 'self-declared');
    expect(receipt.keys, isNot(contains('dateOfBirth')));
  });

  test('age block overrides even an existing accepted receipt', () async {
    final consent = await service();
    await consent.accept(
      ageGroup: DistributionAgeGroup.teen,
      guardianAcknowledged: true,
      diagnosticsAllowed: true,
    );
    expect(consent.diagnosticsAllowed, isTrue);
    await consent.blockAge();
    final restored = DistributionConsentService(await loadConsentPreferences());
    expect(restored.isAgeBlocked, isTrue);
    expect(restored.isAccepted, isFalse);
    expect(restored.diagnosticsAllowed, isFalse);
    await expectLater(
      restored.accept(
        ageGroup: DistributionAgeGroup.adult,
        guardianAcknowledged: false,
        diagnosticsAllowed: false,
      ),
      throwsException,
    );
  });

  test('corrupt, stale and incomplete receipts require setup again', () async {
    final prefs = await SharedPreferences.getInstance();
    final consent = await service();
    final valid = <String, Object?>{
      'version': IDistributionConsentService.version,
      'ageGroup': 'adult',
      'termsAccepted': true,
      'privacyAcknowledged': true,
      'acceptedAt': '2026-11-12T12:00:00.000Z',
      'diagnosticsAllowed': true,
    };
    for (final invalid in [
      '{broken',
      '[]',
      jsonEncode({...valid, 'version': 'old'}),
      jsonEncode({...valid, 'acceptedAt': 'not a date'}),
      jsonEncode({...valid, 'privacyAcknowledged': false}),
      jsonEncode({...valid, 'termsAccepted': false}),
      jsonEncode({...valid, 'ageGroup': 'under16'}),
      jsonEncode({...valid, 'ageGroup': 'teen'}),
    ]) {
      await prefs.setString(IDistributionConsentService.receiptKey, invalid);
      expect(consent.isAccepted, isFalse, reason: invalid);
      expect(consent.diagnosticsAllowed, isFalse, reason: invalid);
    }
    await prefs.setBool(IDistributionConsentService.receiptKey, true);
    expect(consent.isAccepted, isFalse);
  });
}
