import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:sentry_flutter/sentry_flutter.dart';

import 'distribution_consent_service.dart';
import 'public_backend_config.dart';
import 'timeout_http_client.dart';

/// Actual server classification, independent of the device's age declaration.
class CloudAuthorization {
  const CloudAuthorization({
    required this.allowed,
    required this.parentManaged,
    required this.fileSync,
  });
  final bool allowed;
  final bool parentManaged;
  final bool fileSync;
}

/// Sanitized server failure, with a status for expired setup recovery.
class CloudConsentException implements Exception {
  const CloudConsentException(this.statusCode);
  final int statusCode;
  @override
  String toString() =>
      'Cloud permission is unavailable. Please try again or ask your parent to start a new request.';
}

/// Transport usable before Supabase, account creation and push initialization.
class CloudConsentService {
  CloudConsentService({http.Client? client, FlutterSecureStorage? storage})
    : _client = client ?? TimeoutHttpClient(),
      _storage = storage ?? const FlutterSecureStorage();

  static final instance = CloudConsentService();
  static const claimKey = 'parental_consent_claim_v3';
  static final authorization = ValueNotifier<CloudAuthorization?>(null);

  /// Wired after Supabase initializes; stale account responses cannot update UI.
  static String? Function()? currentAccessToken;
  final http.Client _client;
  final FlutterSecureStorage _storage;
  final _requests = <String, Future<CloudAuthorization>>{};

  Future<Map<String, Object?>> call(
    String action, {
    Map<String, Object?> data = const {},
    String? accessToken,
  }) async {
    final response = await _client.post(
      Uri.parse('${PublicBackendConfig.url}/functions/v1/cloud-consent'),
      headers: {
        'apikey': PublicBackendConfig.publishableKey,
        'Content-Type': 'application/json',
        if (accessToken != null) 'Authorization': 'Bearer $accessToken',
      },
      body: jsonEncode({'action': action, ...data}),
    );
    final decoded = jsonDecode(response.body);
    if (response.statusCode != 200 || decoded is! Map<String, Object?>) {
      throw CloudConsentException(response.statusCode);
    }
    return decoded;
  }

  Future<String?> readClaim() => _storage.read(key: claimKey);

  Future<void> saveClaim(String token) =>
      _storage.write(key: claimKey, value: token);

  Future<Map<String, Object?>> poll() async {
    final token = await readClaim();
    if (token == null) throw Exception('Parent setup must be completed.');
    return call('poll', data: {'claimToken': token});
  }

  Future<CloudAuthorization> authorize(String accessToken) async {
    final existing = _requests[accessToken];
    if (existing != null) return existing;
    final request = _authorize(accessToken);
    _requests[accessToken] = request;
    try {
      return await request;
    } finally {
      if (identical(_requests[accessToken], request)) {
        final _ = _requests.remove(accessToken);
      }
    }
  }

  Future<CloudAuthorization> _authorize(String accessToken) async {
    final prefs = await loadConsentPreferences();
    final consent = DistributionConsentService(prefs);
    if (!consent.isAccepted) throw Exception('Complete setup first.');
    final result = await call(
      'authorize',
      accessToken: accessToken,
      data: consent.ageGroup == DistributionAgeGroup.parentManaged
          ? {'claimToken': await readClaim()}
          : {
              'age': 18,
              'country': consent.country,
              'noticeVersion': IDistributionConsentService.version,
              'termsAccepted': true,
              'privacyAcknowledged': true,
              'graduate':
                  prefs.getBool('distribution_graduation_pending') == true,
            },
    );
    final snapshot = CloudAuthorization(
      allowed: result['allowed'] == true,
      parentManaged: result['accountKind'] == 'parent_managed',
      fileSync: result['fileSync'] == true,
    );
    if (snapshot.allowed &&
        snapshot.parentManaged &&
        result['deviceClaim'] is String &&
        (currentAccessToken == null || currentAccessToken!() == accessToken)) {
      // A QR-linked child account needs a consent capability for that actual
      // account on its next pre-auth launch, not the previous local receipt.
      await saveClaim(result['deviceClaim']! as String);
      final country = result['country'];
      if (country is! String) throw const CloudConsentException(503);
      await consent.acceptParentManaged(country: country);
      await prefs.setString('distribution_declared_country', country);
      await prefs.setString(
        'distribution_declared_age',
        '${result['ageAtSetup']}',
      );
    }
    if (snapshot.allowed &&
        result['accountKind'] == 'adult' &&
        prefs.getBool('distribution_graduation_pending') == true) {
      await prefs.remove('distribution_graduation_pending');
      await prefs.setString('distribution_declared_age', '18+');
      await _storage.delete(key: claimKey);
    }
    if (snapshot.parentManaged &&
        prefs.getBool('parent_managed_diagnostics_disabled') != true) {
      await prefs.setBool('parent_managed_diagnostics_disabled', true);
      await Sentry.close();
    }
    if (currentAccessToken == null || currentAccessToken!() == accessToken) {
      authorization.value = snapshot;
    }
    return snapshot;
  }
}
