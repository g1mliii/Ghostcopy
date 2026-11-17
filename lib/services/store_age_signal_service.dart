import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// What the app store says about the user's age, reduced to what setup needs.
///
/// Apple's Declared Age Range and Google Play's Age Signals may be used only
/// to give an age-appropriate experience in this app (Apple DPLA 3.3.3(P),
/// Play Age Signals terms). Nothing here is logged, sent to analytics or
/// persisted: setup turns it into the same age choice a user could have made,
/// and only the store reference used for consent withdrawal leaves the device.
/// See docs/store-age-signals.md.
enum StoreAgeStatus {
  /// The store reports an adult. Setup takes the adult path.
  adult,

  /// The store reports a minor in [StoreAgeSignal.ageLower]..[StoreAgeSignal.ageUpper].
  /// Setup takes the parent-consent path with the age limited to that band.
  minor,

  /// A supervised account whose parent has not approved, or has declined, the
  /// current version (Google Play significantChangeStatus PENDING / DECLINED).
  notApproved,

  /// No usable signal: unsupported OS or region, not installed from the store,
  /// the user or parent declined to share, or an error. Setup asks as before.
  unavailable,
}

/// Which store answered. Matches the server's `store_consent_refs.store`.
enum AppStore { appStore, googlePlay }

@immutable
class StoreAgeSignal {
  const StoreAgeSignal._(
    this.status, {
    this.ageLower,
    this.ageUpper,
    this.store,
    this.storeRef,
    this.pending = false,
    this.significantChangeConsentRequired = false,
  });

  static const unavailable = StoreAgeSignal._(StoreAgeStatus.unavailable);

  final StoreAgeStatus status;

  /// Inclusive bounds; null lower means "from 0", null upper means "and over".
  final int? ageLower;
  final int? ageUpper;
  final AppStore? store;

  /// Apple appTransactionId or Google Play installId. Sent once with the
  /// parent request so a store withdrawal can revoke it; never stored here.
  final String? storeRef;

  /// For [StoreAgeStatus.notApproved]: approval is still pending, not declined.
  final bool pending;

  /// The store requires parental consent for significant changes for this
  /// user (Apple RegulatoryFeature.significantAppChangeRequiresParentalConsent).
  final bool significantChangeConsentRequired;

  /// The ages a minor may choose from in setup, in the existing dropdown's
  /// values. Empty unless [status] is [StoreAgeStatus.minor].
  List<String> get ageChoices {
    if (status != StoreAgeStatus.minor) return const [];
    final lower = ageLower ?? 0;
    final upper = ageUpper ?? 17;
    return [
      if (lower < 5) 'Under 5',
      for (var age = lower < 5 ? 5 : lower; age <= upper && age < 18; age++)
        '$age',
    ];
  }

  /// Map the native channel's normalized answer. Anything unexpected is
  /// [unavailable], which keeps today's self-declared flow.
  factory StoreAgeSignal.fromPlatform(Map<Object?, Object?>? value) {
    if (value == null || value['shared'] != true) return unavailable;
    final store = switch (value['store']) {
      'app_store' => AppStore.appStore,
      'google_play' => AppStore.googlePlay,
      _ => null,
    };
    if (store == null) return unavailable;
    final lower = value['ageLower'];
    final upper = value['ageUpper'];
    if ((lower != null && lower is! int) || (upper != null && upper is! int)) {
      return unavailable;
    }
    final ref = value['storeRef'];
    final storeRef = ref is String && ref.isNotEmpty && ref.length <= 128
        ? ref
        : null;
    final consentRequired = value['significantChangeConsentRequired'] == true;
    final change = value['significantChange'];
    if (change == 'pending' || change == 'declined') {
      return StoreAgeSignal._(
        StoreAgeStatus.notApproved,
        store: store,
        pending: change == 'pending',
      );
    }
    final low = lower as int?;
    final high = upper as int?;
    if (low != null && low >= 18) {
      return StoreAgeSignal._(
        StoreAgeStatus.adult,
        ageLower: low,
        store: store,
      );
    }
    if (high != null && high < 18 && (low ?? 0) <= high) {
      return StoreAgeSignal._(
        StoreAgeStatus.minor,
        ageLower: low,
        ageUpper: high,
        store: store,
        storeRef: storeRef,
        significantChangeConsentRequired: consentRequired,
      );
    }
    return unavailable;
  }
}

/// Outcome of asking the store's parent-consent flow about a significant change.
enum SignificantChangeStatus {
  /// No store consent is needed: not required for this user or region, or the
  /// store has no such flow on this OS.
  notRequired,
  approved,

  /// Asked (or for Play, declared in Play Console) and not yet answered.
  pending,
  declined,
}

abstract class IStoreAgeSignalService {
  /// Ask the store for the user's age category. Never throws.
  Future<StoreAgeSignal> request();

  /// The store's parent answer for significant change [version], whose
  /// user-facing [description] is shown to the parent. With [ask], present
  /// the store's request when none has been sent for this version. Never throws.
  Future<SignificantChangeStatus> significantChange({
    required String version,
    required String description,
    bool ask = false,
  });
}

class StoreAgeSignalService implements IStoreAgeSignalService {
  StoreAgeSignalService({MethodChannel? channel, bool? supported})
    : _channel = channel ?? const MethodChannel('com.ghostcopy/store_age'),
      _supported = supported ?? (Platform.isIOS || Platform.isAndroid);

  final MethodChannel _channel;
  final bool _supported;

  @override
  Future<StoreAgeSignal> request() async {
    if (!_supported) return StoreAgeSignal.unavailable;
    try {
      return StoreAgeSignal.fromPlatform(
        await _channel.invokeMapMethod<Object?, Object?>('requestAgeSignal'),
      );
    } on Object {
      // PlatformException, MissingPluginException (older native build) or a
      // malformed answer: fall back to the self-declared flow.
      return StoreAgeSignal.unavailable;
    }
  }

  @override
  Future<SignificantChangeStatus> significantChange({
    required String version,
    required String description,
    bool ask = false,
  }) async {
    if (!_supported) return SignificantChangeStatus.notRequired;
    try {
      final status = await _channel.invokeMethod<String>('significantChange', {
        'version': version,
        'description': description,
        'ask': ask,
      });
      return SignificantChangeStatus.values.firstWhere(
        (value) => value.name == status,
        orElse: () => SignificantChangeStatus.notRequired,
      );
    } on Object {
      return SignificantChangeStatus.notRequired;
    }
  }
}
