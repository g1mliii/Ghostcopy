import 'package:shared_preferences/shared_preferences.dart';

export 'impl/distribution_consent_service.dart';

/// Locally declared age group. This is not verified parental consent.
enum DistributionAgeGroup { under16, teen, adult }

/// Records notice acknowledgement before any cloud services start.
abstract class IDistributionConsentService {
  static const version = '2026-11-12-v2';
  static const receiptKey = 'distribution_consent_receipt';
  static const blockedKey = 'distribution_age_blocked';

  bool get isAccepted;
  bool get isAgeBlocked;
  bool get diagnosticsAllowed;

  /// Save a locally declared age group and notice version atomically.
  Future<void> accept({
    required DistributionAgeGroup ageGroup,
    required bool guardianAcknowledged,
    required bool diagnosticsAllowed,
  });

  /// Persist an ineligible age choice. No child cloud account is created.
  Future<void> blockAge();
}

/// Kept here so background and UI isolates read the same preference store.
Future<SharedPreferences> loadConsentPreferences() async {
  final preferences = await SharedPreferences.getInstance();
  await preferences.reload();
  return preferences;
}
