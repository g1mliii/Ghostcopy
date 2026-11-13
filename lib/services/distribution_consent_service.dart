import 'package:shared_preferences/shared_preferences.dart';

export 'impl/distribution_consent_service.dart';

/// Locally declared age group. This is not verified parental consent.
enum DistributionAgeGroup { under5, parentManaged, adult }

/// Records notice acknowledgement before any cloud services start.
abstract class IDistributionConsentService {
  static const version = '2026-11-12-v3';
  static const receiptKey = 'distribution_consent_receipt';
  static const blockedKey = 'distribution_age_blocked';

  bool get isAccepted;
  DistributionAgeGroup? get ageGroup;
  bool get isAgeBlocked;
  bool get diagnosticsAllowed;
  String? get country;

  /// Save a locally declared age group and notice version atomically.
  Future<void> accept({
    required DistributionAgeGroup ageGroup,
    required bool diagnosticsAllowed,
    required String country,
  });

  /// Called only after the server confirms verified, purpose-specific consent.
  Future<void> acceptParentManaged({required String country});

  /// Persist an ineligible age choice. No child cloud account is created.
  Future<void> blockAge();
}

/// Kept here so background and UI isolates read the same preference store.
Future<SharedPreferences> loadConsentPreferences() async {
  final preferences = await SharedPreferences.getInstance();
  await preferences.reload();
  return preferences;
}
