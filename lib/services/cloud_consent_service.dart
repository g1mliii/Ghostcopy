import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'distribution_consent_service.dart';
import 'public_backend_config.dart';
import 'timeout_http_client.dart';

/// Actual server classification, independent of the device's age declaration.
class CloudAuthorization {
  const CloudAuthorization({
    required this.allowed,
    required this.parentManaged,
    required this.fileSync,
    this.independentAdult = false,
    this.validUntil,
  });
  final bool allowed;
  final bool parentManaged;
  final bool fileSync;
  final bool independentAdult;
  final DateTime? validUntil;
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
  CloudConsentService({
    http.Client? client,
    FlutterSecureStorage? storage,
    DateTime Function()? now,
  }) : _client = client ?? TimeoutHttpClient(),
       _storage = storage ?? const FlutterSecureStorage(),
       _now = now ?? DateTime.now;

  static final instance = CloudConsentService();
  static const claimKey = 'parental_consent_claim_v3';
  static final authorization = ValueNotifier<CloudAuthorization?>(null);
  static String? _authorizedAccessToken;

  /// When [authorization] was last classified by the server, on the clock of
  /// the service that classified it.
  static DateTime? _authorizedAt;

  /// A previous account's classification cannot authorize a new session's send.
  static CloudAuthorization? authorizationForSession(String accessToken) =>
      _authorizedAccessToken == accessToken ? authorization.value : null;

  /// The one answer to "is this a parent-managed account?".
  ///
  /// Seeded from this device's setup receipt (see [seedParentManaged]) so it is
  /// right before any network call, then replaced by the server's
  /// classification each time [authorize] classifies the current session.
  static final parentManaged = ValueNotifier<bool>(false);

  /// Seed [parentManaged] from the local setup receipt. Call once per isolate
  /// before anything reads it; a later server classification overrides it.
  static void seedParentManaged(SharedPreferences prefs) =>
      parentManaged.value =
          DistributionConsentService(prefs).ageGroup ==
          DistributionAgeGroup.parentManaged;

  /// A cached classification is reused until a parent lease is this close to
  /// expiring. The access guard renews it this long before expiry too.
  static const leaseMargin = Duration(minutes: 2);

  /// How long an account without a lease (an adult) reuses its last check
  /// when the app returns to the foreground.
  static const unleasedCacheAge = Duration(minutes: 5);

  /// [authorizationForSession], but only while it can stand in for a server
  /// check: allowed, and for a parent-managed account, with a lease that has
  /// more than [leaseMargin] left; otherwise no older than [unleasedCacheAge].
  CloudAuthorization? freshAuthorizationForSession(String accessToken) {
    final cached = authorizationForSession(accessToken);
    if (cached == null || !cached.allowed) return null;
    if (!cached.parentManaged) {
      final checkedAt = _authorizedAt;
      return checkedAt != null &&
              _now().difference(checkedAt) < unleasedCacheAge
          ? cached
          : null;
    }
    return cached.validUntil?.isAfter(_now().add(leaseMargin)) == true
        ? cached
        : null;
  }

  /// Wired after Supabase initializes; stale account responses cannot update UI.
  static String? Function()? currentAccessToken;

  /// True unless a wired session getter names a different session.
  static bool _isCurrent(String accessToken) =>
      currentAccessToken == null || currentAccessToken!() == accessToken;
  final http.Client _client;
  final FlutterSecureStorage _storage;
  final DateTime Function() _now;
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
    // A gateway error page is not JSON; keep the status for recovery paths.
    if (response.statusCode != 200) {
      throw CloudConsentException(response.statusCode);
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(response.body);
    } on FormatException {
      throw CloudConsentException(response.statusCode);
    }
    if (decoded is! Map<String, Object?>) {
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

  /// Cancel an unbound request before allowing a different parent email.
  /// Keep the device claim when the server cannot confirm cancellation.
  Future<void> cancelPending() async {
    final token = await readClaim();
    if (token == null) throw Exception('Parent setup must be completed.');
    await call('cancel', data: {'claimToken': token});
    await _storage.delete(key: claimKey);
  }

  /// Do not create a replacement guest for a signed-out, already-bound child.
  /// Account recovery requires a fresh link and PIN from an authorized device.
  Future<void> beforeGuestCreation() async {
    final prefs = await loadConsentPreferences();
    if (prefs.getBool(IDistributionConsentService.cloudPausedKey) == true) {
      throw Exception('Review account setup before signing in.');
    }
    if (parentManaged.value) {
      final status = await poll();
      if (status['status'] != 'authorized' || status['hasAccount'] != false) {
        throw Exception(
          'Link an existing authorized device to recover this account.',
        );
      }
    }
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

  /// Renew a known parent lease only when a send needs it, including in tray
  /// mode. [accessToken] must still identify the current classified session.
  Future<CloudAuthorization> authorizeSend(String accessToken) async {
    if (!_isCurrent(accessToken)) throw const CloudConsentException(401);
    // A refreshed access token has no cached check yet: ask the server for
    // this token rather than refusing until the account guard catches up.
    final cached = authorizationForSession(accessToken);
    if (cached != null &&
        cached.allowed &&
        (!cached.parentManaged ||
            cached.validUntil?.isAfter(_now().add(leaseMargin)) == true)) {
      return cached;
    }
    // authorize() coalesces simultaneous shortcut/file sends for this token.
    final renewed = await authorize(accessToken);
    if (!_isCurrent(accessToken)) throw const CloudConsentException(401);
    if (!renewed.allowed ||
        (renewed.parentManaged &&
            renewed.validUntil?.isAfter(_now()) != true)) {
      throw const CloudConsentException(403);
    }
    return renewed;
  }

  Future<CloudAuthorization> _authorize(String accessToken) async {
    final prefs = await loadConsentPreferences();
    final consent = DistributionConsentService(prefs);
    if (!consent.isAccepted) throw Exception('Complete setup first.');
    final graduating =
        prefs.getBool(IDistributionConsentService.graduationPendingKey) == true;
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
              'graduate': graduating,
            },
    );
    final snapshot = CloudAuthorization(
      allowed: result['allowed'] == true,
      parentManaged: result['accountKind'] == 'parent_managed',
      fileSync: result['fileSync'] == true,
      independentAdult: result['accountKind'] == 'adult',
      validUntil: result['validUntil'] is String
          ? DateTime.tryParse(result['validUntil']! as String)
          : null,
    );
    if (snapshot.allowed &&
        snapshot.parentManaged &&
        result['deviceClaim'] is String &&
        _isCurrent(accessToken)) {
      // A QR-linked child account needs a consent capability for that actual
      // account on its next pre-auth launch, not the previous local receipt.
      await saveClaim(result['deviceClaim']! as String);
      final country = result['country'];
      if (country is! String) throw const CloudConsentException(503);
      await consent.acceptParentManaged(country: country);
      await prefs.setString(
        IDistributionConsentService.declaredCountryKey,
        country,
      );
      await prefs.setString(
        IDistributionConsentService.declaredAgeKey,
        '${result['ageAtSetup']}',
      );
    }
    if (snapshot.allowed &&
        result['accountKind'] == 'adult' &&
        graduating &&
        _isCurrent(accessToken) &&
        prefs.getBool(IDistributionConsentService.graduationPendingKey) ==
            true) {
      await _storage.delete(key: claimKey);
      await prefs.setString(IDistributionConsentService.declaredAgeKey, '18+');
      await prefs.remove(IDistributionConsentService.graduationPendingKey);
    }
    if (_isCurrent(accessToken)) {
      _authorizedAccessToken = accessToken;
      _authorizedAt = _now();
      parentManaged.value = snapshot.parentManaged;
      authorization.value = snapshot;
    }
    return snapshot;
  }
}
