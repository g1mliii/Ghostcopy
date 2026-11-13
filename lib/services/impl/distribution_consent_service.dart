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
    return RegExp(r'^[A-Z]{2}$').hasMatch(country ?? '') &&
        (receipt['ageGroup'] == DistributionAgeGroup.adult.name ||
            (receipt['ageGroup'] == DistributionAgeGroup.parentManaged.name &&
                receipt['verificationMethod'] == 'kws-server-checked'));
  }

  @override
  bool get diagnosticsAllowed =>
      isAccepted &&
      ageGroup == DistributionAgeGroup.adult &&
      _preferences.getBool('parent_managed_diagnostics_disabled') != true &&
      _receipt?['diagnosticsAllowed'] == true;

  @override
  String? get country {
    final value = _receipt?['country'];
    return value is String ? value : null;
  }

  @override
  DistributionAgeGroup? get ageGroup {
    if (!isAccepted) return null;
    return _receipt?['ageGroup'] == DistributionAgeGroup.adult.name
        ? DistributionAgeGroup.adult
        : DistributionAgeGroup.parentManaged;
  }

  @override
  Future<void> accept({
    required DistributionAgeGroup ageGroup,
    required bool diagnosticsAllowed,
    required String country,
  }) async {
    if (isAgeBlocked ||
        ageGroup != DistributionAgeGroup.adult ||
        !RegExp(r'^[A-Z]{2}$').hasMatch(country)) {
      throw Exception('This account is not eligible for cloud setup.');
    }
    final receipt = jsonEncode({
      'version': IDistributionConsentService.version,
      'country': country,
      'ageGroup': ageGroup.name,
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
  Future<void> acceptParentManaged({required String country}) async {
    if (isAgeBlocked || !RegExp(r'^[A-Z]{2}$').hasMatch(country)) {
      throw Exception('This account is not eligible for cloud setup.');
    }
    if (!await _preferences.setString(
      IDistributionConsentService.receiptKey,
      jsonEncode({
        'version': IDistributionConsentService.version,
        'country': country,
        'ageGroup': DistributionAgeGroup.parentManaged.name,
        'termsAccepted': true,
        'privacyAcknowledged': true,
        'diagnosticsAllowed': false,
        'acceptedAt': _now().toUtc().toIso8601String(),
        'verificationMethod': 'kws-server-checked',
      }),
    )) {
      throw Exception('Could not save setup.');
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
