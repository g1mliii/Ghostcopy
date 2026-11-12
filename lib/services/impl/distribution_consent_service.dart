import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../distribution_consent_service.dart';

/// Local acknowledgement only; server authorization and KWS verification are separate.
class DistributionConsentService implements IDistributionConsentService {
  DistributionConsentService(this._preferences, {DateTime Function()? now})
    : _now = now ?? DateTime.now;

  final SharedPreferences _preferences;
  final DateTime Function() _now;

  Map<String, Object?>? get _receipt {
    final raw = _preferences.get(IDistributionConsentService.receiptKey);
    if (raw is! String) return null;
    try {
      final value = jsonDecode(raw);
      if (value is! Map<String, Object?>) return null;
      return value;
    } on FormatException {
      return null;
    }
  }

  @override
  bool get isAgeBlocked =>
      _preferences.get(IDistributionConsentService.blockedKey) == true;

  @override
  bool get isAccepted {
    if (isAgeBlocked) return false;
    final receipt = _receipt;
    if (receipt == null ||
        receipt['version'] != IDistributionConsentService.version ||
        receipt['termsAccepted'] != true ||
        receipt['privacyAcknowledged'] != true ||
        receipt['acceptedAt'] is! String ||
        DateTime.tryParse(receipt['acceptedAt']! as String) == null) {
      return false;
    }
    return receipt['ageGroup'] == DistributionAgeGroup.adult.name ||
        (receipt['ageGroup'] == DistributionAgeGroup.teen.name &&
            receipt['guardianAcknowledged'] == true);
  }

  @override
  bool get diagnosticsAllowed =>
      isAccepted && _receipt?['diagnosticsAllowed'] == true;

  @override
  Future<void> accept({
    required DistributionAgeGroup ageGroup,
    required bool guardianAcknowledged,
    required bool diagnosticsAllowed,
  }) async {
    if (isAgeBlocked ||
        ageGroup == DistributionAgeGroup.under16 ||
        (ageGroup == DistributionAgeGroup.teen && !guardianAcknowledged)) {
      throw Exception('This account is not eligible for cloud setup.');
    }
    final receipt = jsonEncode({
      'version': IDistributionConsentService.version,
      'ageGroup': ageGroup.name,
      'guardianAcknowledged': guardianAcknowledged,
      'termsAccepted': true,
      'privacyAcknowledged': true,
      'diagnosticsAllowed': diagnosticsAllowed,
      'acceptedAt': _now().toUtc().toIso8601String(),
      'verificationMethod': 'self-declared',
    });
    if (!await _preferences.setString(
      IDistributionConsentService.receiptKey,
      receipt,
    )) {
      throw Exception('Could not save setup. Please try again.');
    }
  }

  @override
  Future<void> blockAge() async {
    if (!await _preferences.setBool(
      IDistributionConsentService.blockedKey,
      true,
    )) {
      throw Exception('Could not save your choice. Please try again.');
    }
  }
}
