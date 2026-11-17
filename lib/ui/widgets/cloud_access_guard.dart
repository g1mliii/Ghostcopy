import 'dart:async';
import 'dart:io';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:window_manager/window_manager.dart';

import '../../locator.dart';
import '../../services/auth_service.dart';
import '../../services/cloud_consent_service.dart';
import '../../services/distribution_consent_service.dart';
import '../../services/encryption_service.dart';
import '../../services/impl/encryption_service.dart';
import '../../services/window_service.dart';
import '../platform_adaptive.dart';
import '../screens/distribution_onboarding.dart';
import '../theme/colors.dart';
import 'account_link_recovery_dialog.dart';
import 'passphrase_dialog.dart';

/// Realtime changes to the signed-in user's own `cloud_authorizations` row,
/// as the new row (empty for a delete). RLS limits the feed to that row.
Stream<Map<String, dynamic>> watchCloudAuthorization(
  SupabaseClient client,
  String userId,
) {
  // A unique topic per subscription: the previous one may still be leaving
  // when an account check subscribes again.
  final topic = 'cloud-authorization-$userId-${_watchSequence++}';
  RealtimeChannel? channel;
  late final StreamController<Map<String, dynamic>> changes;
  changes = StreamController<Map<String, dynamic>>(
    onListen: () {
      channel = client
          .channel(topic)
          .onPostgresChanges(
            event: PostgresChangeEvent.all,
            schema: 'public',
            table: 'cloud_authorizations',
            filter: PostgresChangeFilter(
              type: PostgresChangeFilterType.eq,
              column: 'user_id',
              value: userId,
            ),
            callback: (payload) => changes.add(payload.newRecord),
          )
          .subscribe();
    },
    onCancel: () async {
      final subscribed = channel;
      channel = null;
      if (subscribed != null) await client.removeChannel(subscribed);
      await changes.close();
    },
  );
  return changes.stream;
}

var _watchSequence = 0;

/// Rechecks the authenticated account, including after switching accounts,
/// returning to the app and losing a required encryption key.
///
/// A parent-managed account is rechecked once, shortly before its permission
/// lease expires, and at once when [watchAuthorization] reports a change to
/// its authorization row. Returning to the app reuses a still-fresh check.
/// RLS enforces a withdrawal on the server immediately either way; this only
/// decides how soon the UI shows it.
class CloudAccessGuard extends StatefulWidget {
  const CloudAccessGuard({
    required this.builder,
    this.onBlocked,
    this.onAuthorized,
    this.client,
    this.consent,
    this.encryption,
    this.isDesktop,
    this.revokePush,
    this.watchAuthorization,
    this.now,
    super.key,
  });
  final Widget Function() builder;
  final VoidCallback? onBlocked;
  final void Function(CloudAuthorization authorization)? onAuthorized;
  final SupabaseClient? client;
  final CloudConsentService? consent;
  final IEncryptionService? encryption;
  final bool? isDesktop;
  final Future<void> Function()? revokePush;

  /// Usually [watchCloudAuthorization]. Without it, a change shows at the next
  /// lease check, on return to the app once the lease is stale, or on retry.
  final Stream<Map<String, dynamic>> Function(
    SupabaseClient client,
    String userId,
  )?
  watchAuthorization;
  final DateTime Function()? now;

  /// Retry interval while a parent-managed account has no current lease:
  /// waiting for permission, blocked, or offline.
  static const retryWithoutLease = Duration(minutes: 1);

  /// Floor for the lease timer, so a lease the server did not extend cannot
  /// become a tight loop.
  static const minimumLeaseDelay = Duration(seconds: 30);

  /// Floor once a server check came back with the lease already held: the
  /// device clock runs ahead of the server's, which renews only near its own
  /// expiry.
  static const unrenewedLeaseDelay = Duration(minutes: 2);

  @override
  State<CloudAccessGuard> createState() => _CloudAccessGuardState();
}

class _CloudAccessGuardState extends State<CloudAccessGuard>
    with WidgetsBindingObserver, WindowListener {
  StreamSubscription<AuthState>? _auth;
  StreamSubscription<Map<String, dynamic>>? _watch;
  String? _watchedUser;
  Timer? _timer;
  SupabaseClient get _client => widget.client ?? Supabase.instance.client;
  CloudConsentService get _cloud =>
      widget.consent ?? CloudConsentService.instance;
  IEncryptionService get _encryption =>
      widget.encryption ?? EncryptionService.instance;
  DateTime _now() => (widget.now ?? DateTime.now)();
  bool get _parent => CloudConsentService.parentManaged.value;
  bool _ready = false;
  bool _busy = false;
  bool _checkAgain = false;
  bool _forceAgain = false;
  bool _foreground = true;
  bool _notifiedBlocked = false;
  bool _needsKey = false;
  bool _needsAccountLink = false;

  /// Lease of the last allowed parent-managed check; null when none is known.
  DateTime? _validUntil;

  /// The last check due for renewal returned the lease already held: the
  /// device clock is ahead of the server's, which renews only near its own
  /// expiry.
  bool _leaseUnrenewed = false;

  /// Set while an account that has turned 18 confirms independent setup.
  SharedPreferences? _graduation;
  String? _authorizedUser;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (_desktop) windowManager.addListener(this);
    _encryption.keyRevision.addListener(_keyChanged);
    _auth = _client.auth.onAuthStateChange.listen(
      (state) => _onAccountSignal(state.session?.user.id),
      // GoTrue replays failed deep-link/refresh errors as well as auth events.
      // Recheck the actual session without discarding a same-account draft.
      onError: (Object error, StackTrace stackTrace) =>
          _onAccountSignal(_client.auth.currentUser?.id),
    );
    unawaited(_check());
    // Off the startup path: an offline launch must not wait on this.
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => unawaited(_checkGraduation()),
    );
  }

  /// Refreshing the same account must preserve the composer and attachments.
  /// A different account or sign-out immediately removes the private subtree.
  void _onAccountSignal(String? userId) {
    if (mounted && userId != _authorizedUser) {
      _authorizedUser = null;
      _notifyBlocked();
      setState(() {
        _ready = false;
        _needsKey = false;
      });
    }
    unawaited(_check());
  }

  bool get _desktop => widget.isDesktop ?? Adaptive.isDesktop;

  /// One timer, rescheduled after every check: [CloudConsentService.leaseMargin]
  /// before the lease expires, or [CloudAccessGuard.retryWithoutLease] while
  /// there is none.
  void _maintainTimer() {
    _timer?.cancel();
    _timer = null;
    if (!mounted) return;
    final visible =
        !_desktop ||
        !locator.isRegistered<IWindowService>() ||
        locator<IWindowService>().isVisible;
    if (!_parent || !_foreground || !visible) return;
    final lease = _validUntil;
    // Not renewed: wait until the lease's expiry, when the server will.
    final margin = _leaseUnrenewed
        ? Duration.zero
        : CloudConsentService.leaseMargin;
    final floor = _leaseUnrenewed
        ? CloudAccessGuard.unrenewedLeaseDelay
        : CloudAccessGuard.minimumLeaseDelay;
    var delay = lease == null
        ? CloudAccessGuard.retryWithoutLease
        : lease.difference(_now()) - margin;
    if (delay < floor) delay = floor;
    _timer = Timer(delay, () {
      _timer = null;
      unawaited(_check(force: true));
    });
  }

  /// Follow a parent-managed account's own authorization row while signed in.
  void _maintainWatch() {
    final watch = widget.watchAuthorization;
    final wanted = mounted && watch != null && _parent
        ? _client.auth.currentUser?.id
        : null;
    if (wanted == _watchedUser) return;
    unawaited(_watch?.cancel());
    _watch = null;
    _watchedUser = wanted;
    if (wanted != null) {
      _watch = watch!(_client, wanted).listen(_authorizationRowChanged);
    }
  }

  /// Lease renewals update the row too; only a change that would alter the
  /// answer needs a server check.
  void _authorizationRowChanged(Map<String, dynamic> row) {
    final token = _client.auth.currentSession?.accessToken;
    final cached = token == null
        ? null
        : _cloud.freshAuthorizationForSession(token);
    if (cached != null &&
        row['status'] == 'authorized' &&
        row['cloud_sync'] == true &&
        row['file_sync'] == cached.fileSync &&
        (row['account_kind'] == 'parent_managed') == cached.parentManaged) {
      return;
    }
    unawaited(_check(force: true));
  }

  /// A parent-managed account that has turned 18 confirms independent setup
  /// once. Asked after the first frame rather than before runApp.
  Future<void> _checkGraduation() async {
    try {
      final prefs = await loadConsentPreferences();
      if (!_parent ||
          prefs.getBool(IDistributionConsentService.cloudPausedKey) == true) {
        return;
      }
      if (prefs.getBool(IDistributionConsentService.graduationPendingKey) !=
          true) {
        final status = await _cloud.poll();
        if (status['independentEligible'] != true) return;
        await prefs.setBool(
          IDistributionConsentService.graduationPendingKey,
          true,
        );
      }
      if (!mounted) return;
      _notifyBlocked();
      setState(() => _graduation = prefs);
    } on Exception {
      // Offline or no claim: permission checks carry on, and eligibility is
      // asked again on the next launch.
    }
  }

  void _graduated() {
    if (!mounted) return;
    setState(() => _graduation = null);
    unawaited(_check(force: true));
  }

  @override
  void onWindowBlur() {
    _foreground = false;
    _maintainTimer();
  }

  @override
  void onWindowFocus() {
    _foreground = true;
    unawaited(_check());
  }

  void _keyChanged() => unawaited(_check());

  void _notifyBlocked() {
    if (!mounted) return;
    if (_notifiedBlocked) return;
    _notifiedBlocked = true;
    widget.onBlocked?.call();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _maintainTimer();
    if (state == AppLifecycleState.resumed) unawaited(_check());
  }

  /// [force] skips a still-fresh cached classification: the lease timer, a
  /// changed authorization row, and the user asking to try again.
  Future<void> _check({bool force = false}) async {
    if (!mounted) return;
    if (_busy) {
      _checkAgain = true;
      _forceAgain |= force;
      return;
    }
    _busy = true;
    var session = _client.auth.currentSession;
    var checkedUser = session?.user.id;
    try {
      final prefs = await loadConsentPreferences();
      final paused =
          prefs.getBool(IDistributionConsentService.cloudPausedKey) == true;
      if (session == null && _parent && !paused) {
        _validUntil = null;
        final status = await _cloud.poll();
        if (_client.auth.currentSession != null) {
          _checkAgain = true;
          return;
        }
        if (status['hasAccount'] != false) {
          if (mounted) {
            _notifyBlocked();
            setState(() {
              _ready = false;
              _needsAccountLink = true;
              _error =
                  'Link another signed-in GhostCopy device to restore your existing account. If no device is available, contact support@ghostcopy.app with your parent. Parent permission alone cannot sign you back in.';
            });
          }
          return;
        }
        if (status['status'] != 'authorized') {
          throw const CloudConsentException(403);
        }
        await locator<IAuthService>().initialize();
        session = _client.auth.currentSession;
        checkedUser = session?.user.id;
      }
      _needsAccountLink = false;
      if (session == null) {
        _validUntil = null;
        if (paused) throw const CloudConsentException(401);
        if (mounted) {
          setState(() {
            _ready = true;
            _error = null;
          });
        }
        return;
      }
      final held = _validUntil;
      // Due for renewal by this device's clock, so the server should extend it.
      final due =
          held != null &&
          !held.isAfter(_now().add(CloudConsentService.leaseMargin));
      final cached = force
          ? null
          : _cloud.freshAuthorizationForSession(session.accessToken);
      final snapshot = cached ?? await _cloud.authorize(session.accessToken);
      // A late response from the previous account must not reveal its screen.
      if (_client.auth.currentUser?.id != session.user.id) {
        return;
      }
      final lease = snapshot.allowed && snapshot.parentManaged
          ? snapshot.validUntil
          : null;
      if (cached == null) _leaseUnrenewed = due && lease == held;
      _validUntil = lease;
      if (!snapshot.allowed) {
        throw const CloudConsentException(403);
      }
      await _encryption.initialize(session.user.id);
      final needsKey = snapshot.parentManaged && !await _encryption.isEnabled();
      if (_client.auth.currentUser?.id != checkedUser || !mounted) return;
      if (needsKey) _notifyBlocked();
      if (!needsKey) _notifiedBlocked = false;
      if (!needsKey && _authorizedUser != session.user.id) {
        _authorizedUser = session.user.id;
        widget.onAuthorized?.call(snapshot);
      }
      if (mounted) {
        setState(() {
          _needsKey = needsKey;
          _ready = !needsKey;
          _error = null;
        });
      }
    } on Exception catch (error) {
      // A failed check belonging to an account we left cannot block its successor.
      if (_client.auth.currentUser?.id != checkedUser) return;
      _validUntil = null;
      _authorizedUser = null;
      _notifyBlocked();
      // A timeout or key-storage failure is not withdrawn permission.
      if (error is CloudConsentException &&
          (error.statusCode == 401 || error.statusCode == 403)) {
        try {
          await (widget.revokePush?.call() ?? _revokePush());
        } on Exception {
          /* Firebase may not have started. */
        }
      }
      if (mounted) {
        setState(() {
          _ready = false;
          _error = _client.auth.currentSession == null
              ? 'Signed out. Review account setup when you are ready.'
              : 'Cloud access is paused. Check your connection or review account permission.';
        });
      }
    } finally {
      _busy = false;
      _maintainTimer();
      _maintainWatch();
      if (_checkAgain && mounted) {
        final force = _forceAgain;
        _checkAgain = false;
        _forceAgain = false;
        unawaited(_check(force: force));
      }
    }
  }

  Future<void> _revokePush() async {
    if (Platform.isAndroid || Platform.isIOS) {
      // Recorded first: even a partial revoke needs a new token later.
      final prefs = await loadConsentPreferences();
      await prefs.setBool(IDistributionConsentService.pushRevokedKey, true);
      await FirebaseMessaging.instance.setAutoInitEnabled(false);
      await FirebaseMessaging.instance.deleteToken();
    }
  }

  Future<void> _setKey() async {
    final id = _client.auth.currentUser?.id;
    if (id == null) return;
    await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) =>
          PassphraseDialog(encryptionService: _encryption, userId: id),
    );
    await _check();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (_desktop) windowManager.removeListener(this);
    _encryption.keyRevision.removeListener(_keyChanged);
    unawaited(_auth?.cancel());
    unawaited(_watch?.cancel());
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final graduation = _graduation;
    if (graduation != null) {
      return DistributionOnboarding(
        prefs: graduation,
        cloud: _cloud,
        onAccepted: _graduated,
      );
    }
    if (_ready) return widget.builder();
    return Scaffold(
      backgroundColor: GhostColors.background,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.lock_outline, size: 40),
                  const SizedBox(height: 20),
                  Text(
                    _needsKey
                        ? 'Protect your clips'
                        : _needsAccountLink
                        ? 'Restore your account'
                        : 'Checking cloud permission',
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    _needsKey
                        ? 'A passphrase is required for this parent-managed account. It stays on your devices; GhostCopy and your parent cannot read encrypted clips without it. Keep a safe copy.'
                        : _error ?? 'Please wait…',
                  ),
                  const SizedBox(height: 20),
                  if (_needsKey)
                    FilledButton(
                      onPressed: () => unawaited(_setKey()),
                      child: const Text('Set or restore passphrase'),
                    ),
                  if (_error != null) ...[
                    if (_needsAccountLink)
                      FilledButton(
                        onPressed: () => unawaited(_linkAccount()),
                        child: const Text('Link existing device'),
                      ),
                    TextButton(
                      onPressed: () => unawaited(_requestPermission()),
                      child: Text(
                        _parent
                            ? 'Ask for parent permission again'
                            : 'Review account setup',
                      ),
                    ),
                    FilledButton(
                      onPressed: () => unawaited(_check(force: true)),
                      child: const Text('Try again'),
                    ),
                    if (_client.auth.currentSession != null)
                      TextButton(
                        onPressed: () => unawaited(_signOut()),
                        child: const Text('Sign out and pause setup'),
                      ),
                    TextButton(
                      onPressed: () => unawaited(
                        launchUrl(
                          Uri.https('ghostcopy.app', 'parents'),
                          mode: LaunchMode.externalApplication,
                        ),
                      ),
                      child: const Text('Parent controls and data requests'),
                    ),
                    if (_client.auth.currentSession != null)
                      TextButton(
                        onPressed: () => unawaited(_delete()),
                        child: const Text('Delete this account'),
                      ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _linkAccount() async {
    await showDialog<bool>(
      context: context,
      builder: (_) => AccountLinkRecoveryDialog(
        client: _client,
        auth: locator<IAuthService>(),
      ),
    );
    await _check();
  }

  Future<void> _requestPermission() async {
    final prefs = await loadConsentPreferences();
    if (!mounted) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (context) => DistributionOnboarding(
          prefs: prefs,
          parentAccount: _parent,
          onAccepted: () => Navigator.of(context).pop(),
        ),
      ),
    );
    await _check(force: true);
  }

  Future<void> _signOut() async {
    // signOut(createGuest: false) pauses cloud setup itself, and only once the
    // sign-out can no longer fail part-way.
    try {
      await locator<IAuthService>().signOut(createGuest: false);
      CloudConsentService.authorization.value = null;
    } on Exception {
      if (mounted) {
        setState(() => _error = 'Could not sign out. Please try again.');
      }
    }
    await _check();
  }

  Future<void> _delete() async {
    final userId = _client.auth.currentUser?.id;
    if (userId == null) return;
    final confirmed = await Adaptive.confirm(
      context,
      title: 'Delete this account?',
      message:
          'This permanently removes the cloud account and its saved clips. It cannot be undone.',
      confirmText: 'Delete account',
      isDestructive: true,
    );
    if (!confirmed || _client.auth.currentUser?.id != userId) return;
    try {
      await locator<IAuthService>().deleteAccount();
    } on Exception {
      if (mounted) {
        setState(
          () => _error =
              'Could not delete the account. Contact support@ghostcopy.app.',
        );
      }
    }
    await _check();
  }
}
