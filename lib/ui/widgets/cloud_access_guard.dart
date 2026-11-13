import 'dart:async';
import 'dart:io';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
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
import '../screens/distribution_onboarding.dart';
import '../theme/colors.dart';
import 'account_link_recovery_dialog.dart';
import 'passphrase_dialog.dart';

/// Rechecks the authenticated account, including after switching accounts,
/// returning to the app and losing a required encryption key.
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

  @override
  State<CloudAccessGuard> createState() => _CloudAccessGuardState();
}

class _CloudAccessGuardState extends State<CloudAccessGuard>
    with WidgetsBindingObserver, WindowListener {
  StreamSubscription<AuthState>? _auth;
  Timer? _timer;
  SupabaseClient get _client => widget.client ?? Supabase.instance.client;
  CloudConsentService get _cloud =>
      widget.consent ?? CloudConsentService.instance;
  IEncryptionService get _encryption =>
      widget.encryption ?? EncryptionService.instance;
  bool _ready = false;
  bool _busy = false;
  bool _checkAgain = false;
  bool _foreground = true;
  bool _notifiedBlocked = false;
  bool _needsKey = false;
  bool _parent = false;
  bool _needsAccountLink = false;
  String? _authorizedUser;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (_desktop) windowManager.addListener(this);
    _encryption.keyRevision.addListener(_keyChanged);
    _auth = _client.auth.onAuthStateChange.listen((state) {
      // Refreshing the same account must preserve the composer and attachments.
      // A different account or sign-out immediately removes the private subtree.
      if (mounted && state.session?.user.id != _authorizedUser) {
        _authorizedUser = null;
        _notifyBlocked();
        setState(() {
          _ready = false;
          _needsKey = false;
        });
      }
      unawaited(_check());
    });
    unawaited(_check());
  }

  bool get _desktop =>
      widget.isDesktop ??
      (Platform.isWindows || Platform.isMacOS || Platform.isLinux);

  void _maintainTimer() {
    if (!mounted) {
      _timer?.cancel();
      _timer = null;
      return;
    }
    final visible =
        !_desktop ||
        !locator.isRegistered<IWindowService>() ||
        locator<IWindowService>().isVisible;
    if (_parent && _foreground && visible) {
      _timer ??= Timer.periodic(
        const Duration(minutes: 1),
        (_) => unawaited(_check()),
      );
    } else {
      _timer?.cancel();
      _timer = null;
    }
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

  Future<void> _check() async {
    if (!mounted) return;
    if (_busy) {
      _checkAgain = true;
      return;
    }
    _busy = true;
    var session = _client.auth.currentSession;
    var checkedUser = session?.user.id;
    try {
      final local = DistributionConsentService(await loadConsentPreferences());
      final prefs = await loadConsentPreferences();
      final paused = prefs.getBool('distribution_cloud_paused') == true;
      if (session == null &&
          local.ageGroup == DistributionAgeGroup.parentManaged &&
          !paused) {
        _parent = true;
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
        if (paused) {
          _parent = local.ageGroup == DistributionAgeGroup.parentManaged;
          throw const CloudConsentException(401);
        }
        if (mounted) {
          setState(() {
            _ready = true;
            _error = null;
          });
        }
        return;
      }
      final snapshot = await _cloud.authorize(session.accessToken);
      // A late response from the previous account must not reveal its screen.
      if (_client.auth.currentUser?.id != session.user.id) {
        return;
      }
      _parent = snapshot.parentManaged;
      if (!snapshot.allowed) {
        throw const CloudConsentException(403);
      }
      await _encryption.initialize(session.user.id);
      final needsKey = _parent && !await _encryption.isEnabled();
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
      if (_checkAgain && mounted) {
        _checkAgain = false;
        unawaited(_check());
      }
    }
  }

  Future<void> _revokePush() async {
    if (Platform.isAndroid || Platform.isIOS) {
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
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
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
                      onPressed: () => unawaited(_check()),
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
    await _check();
  }

  Future<void> _signOut() async {
    final prefs = await loadConsentPreferences();
    await prefs.setBool('distribution_cloud_paused', true);
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
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete this account?'),
        content: const Text(
          'This permanently removes the cloud account and its saved clips. It cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete account'),
          ),
        ],
      ),
    );
    if (confirmed != true || _client.auth.currentUser?.id != userId) return;
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
