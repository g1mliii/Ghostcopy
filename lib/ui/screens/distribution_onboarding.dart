import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:window_manager/window_manager.dart';

import '../../services/cloud_consent_service.dart';
import '../../services/consent_countries.dart';
import '../../services/distribution_consent_service.dart';
import '../../services/settings_service.dart';
import '../../services/store_age_signal_service.dart';
import '../../utils/auth_errors.dart';
import '../platform_adaptive.dart';
import '../theme/app_theme.dart';
import '../theme/appearance.dart';
import '../theme/colors.dart';

/// Runs before cloud, crash-reporting, authentication and clipboard services.
/// Headless processes cannot bypass the first interactive acknowledgement.
///
/// An accepted receipt returns at once, with no network call: a parent-managed
/// account's permission and graduation checks run inside CloudAccessGuard
/// after the first frame, so an offline launch is not held on a blank screen.
Future<void> ensureDistributionConsent({
  required bool headless,
  CloudConsentService? cloud,
}) async {
  final prefs = await loadConsentPreferences();
  CloudConsentService.seedParentManaged(prefs);
  final consent = DistributionConsentService(prefs);
  if (consent.isAccepted &&
      prefs.getBool(IDistributionConsentService.cloudPausedKey) != true) {
    return;
  }
  if (headless) throw Exception('Open GhostCopy to complete setup first.');
  final saved = prefs.getString('theme_mode');
  appAppearance.value = AppThemeMode.values.firstWhere(
    (mode) => mode.name == saved,
    orElse: () => AppThemeMode.system,
  );
  final ready = Completer<void>();
  runApp(
    AppearanceBuilder(
      builder: (_) => MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.platformTheme,
        home: DistributionOnboarding(
          prefs: prefs,
          onAccepted: ready.complete,
          cloud: cloud,
        ),
      ),
    ),
  );
  final desktop = Adaptive.isDesktop;
  if (desktop) {
    await windowManager.ensureInitialized();
    await windowManager.waitUntilReadyToShow(
      WindowOptions(
        size: const Size(540, 720),
        center: true,
        skipTaskbar: false,
        title: 'GhostCopy setup',
        titleBarStyle: TitleBarStyle.normal,
        backgroundColor: GhostColors.background,
      ),
    );
    if (Platform.isMacOS) {
      await _setupPresence.invokeMethod<void>('setInAppSwitcher', true);
    }
    await windowManager.show();
    await windowManager.focus();
  }
  await ready.future;
  if (desktop) {
    // Return the window to the normal hidden tray startup after setup.
    await windowManager.hide();
    if (Platform.isMacOS) {
      await _setupPresence.invokeMethod<void>('setInAppSwitcher', false);
    }
  }
}

const _setupPresence = MethodChannel('com.ghostcopy/app_presence');

/// Three short setup steps, using the same appearance and tokens as the app.
class DistributionOnboarding extends StatefulWidget {
  const DistributionOnboarding({
    required this.prefs,
    required this.onAccepted,
    this.cloud,
    this.parentAccount = false,
    this.storeAge,
    super.key,
  });
  final SharedPreferences prefs;
  final VoidCallback onAccepted;
  final CloudConsentService? cloud;
  final bool parentAccount;

  /// The app store's age signal. Defaults to the platform channel.
  final IStoreAgeSignalService? storeAge;

  @override
  State<DistributionOnboarding> createState() => _DistributionOnboardingState();
}

class _DistributionOnboardingState extends State<DistributionOnboarding> {
  int _step = 0;
  String? _age;
  String? _country;
  bool _agreed = false;
  bool _diagnostics = false;
  bool _saving = false;
  bool _completed = false;
  bool _pending = false;
  bool _hasAccount = false;
  String? _error;
  final _parentEmail = TextEditingController();
  late final _cloud = widget.cloud ?? CloudConsentService.instance;
  late final IDistributionConsentService _consent = DistributionConsentService(
    widget.prefs,
  );
  late bool _blocked = _consent.isAgeBlocked;
  late final IStoreAgeSignalService _store =
      widget.storeAge ?? StoreAgeSignalService();

  /// The store's answer, held only for this setup. Null while not asked.
  StoreAgeSignal? _signal;
  bool _checkingStore = false;

  /// The store has not been asked yet. It is asked only when the user taps
  /// Continue on the first step, never on its own: the store's sheet or Play's
  /// verification screen must not appear before the user does anything.
  bool _storeUnasked = false;

  bool get _adult => _age == '18+';

  bool get _storeAdult => _signal?.status == StoreAgeStatus.adult;
  bool get _storeMinor => _signal?.status == StoreAgeStatus.minor;
  bool get _storeNotApproved => _signal?.status == StoreAgeStatus.notApproved;

  String get _storeName =>
      _signal?.store == AppStore.googlePlay ? 'Google Play' : 'Apple Account';

  /// A parent-managed account re-consenting after the parental notice
  /// changed: the store's significant-change consent applies too.
  bool get _significantChange {
    final approved = widget.prefs.getString(
      IDistributionConsentService.storeConsentNoticeKey,
    );
    return approved != null && approved != IDistributionConsentService.version;
  }

  static String get _changeDescription =>
      'GhostCopy updated its parental notice (${IDistributionConsentService.version}). '
      'Review what changed at ghostcopy.app/parents before allowing cloud sync again.';

  @override
  void initState() {
    super.initState();
    _age = widget.prefs.getString(IDistributionConsentService.declaredAgeKey);
    if (widget.parentAccount && _age == '18+') _age = null;
    _country = widget.prefs.getString(
      IDistributionConsentService.declaredCountryKey,
    );
    if (widget.prefs.getBool(
          IDistributionConsentService.graduationPendingKey,
        ) ==
        true) {
      _age = '18+';
      _step = 1;
      return;
    }
    if (_age != null && _country != null && !_adult && !_blocked) {
      unawaited(_restorePending());
    }
    // The store's age category replaces the age question when it has one.
    // A saved age is the user's earlier answer and is not asked again.
    _storeUnasked =
        _age == null &&
        !widget.parentAccount &&
        !_blocked &&
        _store.isSupported;
  }

  Future<void> _askStore() async {
    setState(() {
      _checkingStore = true;
      _error = null;
    });
    final signal = await _store.request();
    if (!mounted) return;
    setState(() {
      _checkingStore = false;
      _storeUnasked = false;
      _signal = signal;
      switch (signal.status) {
        case StoreAgeStatus.adult:
          _age = '18+';
        case StoreAgeStatus.minor:
          final lower = '${signal.ageLower ?? 0}';
          final choices = signal.ageChoices;
          _age = choices.contains(lower)
              ? lower
              : choices.length == 1
              ? choices.single
              : null;
        case StoreAgeStatus.notApproved:
        case StoreAgeStatus.unavailable:
          _age = null;
      }
    });
  }

  Future<void> _restorePending() async {
    try {
      final token = await _cloud.readClaim();
      if (token != null && mounted) {
        setState(() {
          _pending = true;
          _step = 2;
        });
      }
    } on Exception {
      if (mounted) setState(() => _error = 'Could not restore parent setup.');
    }
  }

  @override
  void dispose() {
    _parentEmail
      ..clear()
      ..dispose();
    super.dispose();
  }

  Future<void> _next() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      if (_step == 0) {
        await widget.prefs.setString(
          IDistributionConsentService.declaredAgeKey,
          _age!,
        );
        await widget.prefs.setString(
          IDistributionConsentService.declaredCountryKey,
          _country!,
        );
        if (_age == 'Under 5') {
          await _consent.blockAge();
          if (mounted) setState(() => _blocked = true);
        } else {
          if (!_adult) {
            final config = await _cloud.call('configuration');
            if (config['childrenEnabled'] != true) {
              throw Exception(
                'Parent setup is not available yet. Cloud services will stay off.',
              );
            }
          }
          if (mounted) setState(() => _step = 1);
        }
      } else if (_step == 1) {
        if (mounted) setState(() => _step = 2);
      } else if (_adult) {
        await _consent.accept(
          ageGroup: DistributionAgeGroup.adult,
          diagnosticsAllowed: _diagnostics,
          country: _country!,
        );
        await widget.prefs.setBool(
          IDistributionConsentService.cloudPausedKey,
          false,
        );
        _finish();
      } else if (!_pending) {
        final signal = _signal;
        final result = await _cloud.call(
          'start',
          data: {
            'age': int.parse(_age!),
            'country': _country,
            'parentEmail': _parentEmail.text.trim(),
            'noticeVersion': IDistributionConsentService.version,
            'noticeAcknowledged': true,
            if (signal?.storeRef != null && signal?.store != null)
              'storeRef': {
                'store': signal!.store == AppStore.appStore
                    ? 'app_store'
                    : 'google_play',
                'id': signal.storeRef,
              },
          },
        );
        final token = result['claimToken'];
        if (token is! String) {
          throw Exception('Could not start parent verification.');
        }
        await _cloud.saveClaim(token);
        _parentEmail.clear();
        if (mounted) setState(() => _pending = true);
        if (_significantChange) {
          // Apple: asks the child to send the store's significant-change
          // request to their parent. Play: the change is declared in Play
          // Console, so there is nothing to present.
          await _store.significantChange(
            version: IDistributionConsentService.version,
            description: _changeDescription,
            ask: true,
          );
        }
      } else {
        final result = await _cloud.poll();
        _hasAccount = result['hasAccount'] == true;
        if (result['independentEligible'] == true) {
          await widget.prefs.setBool(
            IDistributionConsentService.graduationPendingKey,
            true,
          );
          if (mounted) {
            setState(() {
              _age = '18+';
              _step = 1;
              _agreed = false;
              _pending = false;
            });
          }
          return;
        }
        if (result['status'] != 'authorized') {
          if (result['status'] == 'expired' || result['status'] == 'revoked') {
            if (mounted) setState(() => _pending = false);
          }
          throw Exception(
            result['status'] == 'expired'
                ? 'This request expired. Send a new parent request.'
                : 'Waiting for your parent to verify and allow cloud sync.',
          );
        }
        if (_significantChange) {
          final change = await _store.significantChange(
            version: IDistributionConsentService.version,
            description: _changeDescription,
          );
          if (change == SignificantChangeStatus.declined) {
            throw Exception(
              'Your parent declined this GhostCopy update in Screen Time or Family Link. Cloud services stay off.',
            );
          }
          if (change == SignificantChangeStatus.pending) {
            throw Exception(
              'Waiting for your parent to approve this GhostCopy update in Screen Time or Family Link.',
            );
          }
        }
        await _consent.acceptParentManaged(country: _country!);
        await widget.prefs.setBool(
          IDistributionConsentService.cloudPausedKey,
          false,
        );
        _finish();
      }
    } on Exception catch (error) {
      if (!_adult &&
          error is CloudConsentException &&
          (error.statusCode == 403 || error.statusCode == 404)) {
        _pending = false;
      }
      if (mounted) {
        setState(() => _error = authErrorMessage(error));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _restartParentRequest() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await _cloud.cancelPending();
      if (mounted) setState(() => _pending = false);
    } on Exception catch (error) {
      if (mounted) {
        setState(() {
          if (error is CloudConsentException && error.statusCode == 409) {
            _hasAccount = true;
            _error =
                'This request already has an account. Check permission or link an existing device to recover it.';
          } else {
            _error = 'Could not cancel this request. Please try again.';
          }
        });
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _finish() {
    if (!mounted) return;
    // Until the server classifies the new session, the receipt just written
    // is the best answer.
    CloudConsentService.seedParentManaged(widget.prefs);
    setState(() => _completed = true);
    widget.onAccepted();
  }

  String _bandLabel() {
    final lower = _signal?.ageLower;
    final upper = _signal?.ageUpper;
    return lower == null ? 'under ${upper! + 1}' : '$lower–$upper';
  }

  Future<void> _openPolicy(String path) async {
    try {
      if (!await launchUrl(
        Uri.https('ghostcopy.app', path),
        mode: LaunchMode.externalApplication,
      )) {
        throw Exception('Cannot open policy');
      }
    } on Exception {
      if (mounted) {
        setState(
          () => _error = 'Visit ghostcopy.app/$path to read this notice.',
        );
      }
    }
  }

  Widget _policies() => Wrap(
    children: [
      TextButton(
        onPressed: () => unawaited(_openPolicy('terms')),
        child: const Text('Terms of service'),
      ),
      TextButton(
        onPressed: () => unawaited(_openPolicy('privacy')),
        child: const Text('Privacy policy'),
      ),
      if (!_adult)
        TextButton(
          onPressed: () => unawaited(_openPolicy('parents')),
          child: const Text('For parents'),
        ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final enabled =
        !_saving &&
        !_completed &&
        !_checkingStore &&
        (_step == 0
            ? _storeUnasked || _age != null && _country != null
            : _step != 1 || _agreed);
    final waiting = _step == 0 && _storeNotApproved && !_blocked;
    return PopScope(
      canPop: false,
      child: Scaffold(
        backgroundColor: GhostColors.background,
        body: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Icon(
                      Icons.shield_outlined,
                      size: 40,
                      color: GhostColors.actionText,
                    ),
                    const SizedBox(height: 24),
                    Text(
                      _blocked
                          ? 'Cloud setup is unavailable'
                          : waiting
                          ? 'Waiting for a parent'
                          : [
                              'Before we begin',
                              'Your choice, clearly',
                              if (_adult)
                                'Know what you sync'
                              else
                                'Ask your parent',
                            ][_step],
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                    const SizedBox(height: 16),
                    if (_blocked)
                      const Text(
                        'GhostCopy does not create cloud accounts for children under 5. Cloud services stay off. For an existing account or an age entered by mistake, contact support@ghostcopy.app.',
                      )
                    else if (waiting) ...[
                      Text(
                        _signal!.pending
                            ? 'Your parent has not approved this version of GhostCopy in Family Link yet. Cloud services stay off until they do. Ask them to review it, then check again.'
                            : 'Your parent declined this version of GhostCopy in Family Link, so cloud services stay off. If they change their mind in Family Link, check again.',
                      ),
                      const SizedBox(height: 24),
                      FilledButton(
                        onPressed: _checkingStore
                            ? null
                            : () => unawaited(_askStore()),
                        child: Text(
                          _checkingStore ? 'Please wait…' : 'Check again',
                        ),
                      ),
                    ] else ...[
                      Text(
                        'Step ${_step + 1} of 3',
                        style: TextStyle(color: GhostColors.textSecondary),
                      ),
                      const SizedBox(height: 20),
                      if (_step == 0) ...[
                        Text(
                          _checkingStore
                              ? 'Checking the age setting on your app store account…'
                              : _storeUnasked
                              ? 'GhostCopy sends the clips you choose to your linked devices. Cloud services stay off until setup is complete. Continue to check the age shared by your App Store or Google Play account. If it is not shared, you can enter your age instead. We do not ask for your date of birth.'
                              : _storeAdult
                              ? 'GhostCopy sends the clips you choose to your linked devices. Cloud services stay off until setup is complete. Your $_storeName shares that you are 18 or older, so tell us your country to show the right setup.'
                              : _storeMinor
                              ? 'GhostCopy sends the clips you choose to your linked devices. Cloud services stay off until a parent gives permission. Your $_storeName shares an age range of ${_bandLabel()}. Choose your age and country. We do not ask for your date of birth.'
                              : 'GhostCopy sends the clips you choose to your linked devices. Cloud services stay off until setup is complete. Tell us your age and country so we can show the right setup. We do not ask for your date of birth.',
                        ),
                        const SizedBox(height: 16),
                        if (!_storeAdult && !_checkingStore && !_storeUnasked)
                          DropdownButtonFormField<String>(
                            // Rebuilt when the store's answer narrows the choices.
                            key: ValueKey(_signal?.status),
                            initialValue: _age,
                            decoration: const InputDecoration(labelText: 'Age'),
                            items: [
                              for (final age
                                  in _storeMinor
                                      ? _signal!.ageChoices
                                      : [
                                          'Under 5',
                                          for (var i = 5; i < 18; i++) '$i',
                                          if (!widget.parentAccount) '18+',
                                        ])
                                DropdownMenuItem(value: age, child: Text(age)),
                            ],
                            onChanged:
                                _saving ||
                                    widget.prefs.containsKey(
                                          IDistributionConsentService
                                              .declaredAgeKey,
                                        ) &&
                                        widget.prefs.getString(
                                              IDistributionConsentService
                                                  .declaredAgeKey,
                                            ) ==
                                            _age
                                ? null
                                : (value) => setState(() => _age = value),
                          ),
                        if (!_storeUnasked) ...[
                          const SizedBox(height: 16),
                          DropdownButtonFormField<String>(
                            initialValue: _country,
                            isExpanded: true,
                            decoration: const InputDecoration(
                              labelText: 'Country or region',
                            ),
                            items: [
                              for (final country in consentCountries.entries)
                                DropdownMenuItem(
                                  value: country.key,
                                  child: Text(
                                    country.value,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                            ],
                            onChanged: _saving
                                ? null
                                : (value) => setState(() => _country = value),
                          ),
                        ],
                        _policies(),
                      ],
                      if (_step == 1) ...[
                        Text(
                          _adult
                              ? 'Your cloud account stores sent clips, account details and linked-device identifiers. Encryption is optional for adult accounts. Without a passphrase, the service can read synced content. Delete clips or your account in Settings.'
                              : 'A parent must verify they are an adult and give permission before your cloud account starts. Your parent can review permissions, request your saved data, stop syncing or delete your account. Your clips require a passphrase and are encrypted before upload. Keep the passphrase safe: we cannot recover it. Sending is manual; diagnostics and rating prompts stay off.',
                        ),
                        _policies(),
                        CheckboxListTile(
                          contentPadding: EdgeInsets.zero,
                          value: _agreed,
                          onChanged: _saving
                              ? null
                              : (value) =>
                                    setState(() => _agreed = value ?? false),
                          title: Text(
                            _adult
                                ? 'I agree to the terms and acknowledge the privacy policy.'
                                : 'I have read how parent setup and cloud sync work. My parent will review the terms and give permission.',
                          ),
                        ),
                      ],
                      if (_step == 2 && _adult) ...[
                        const Text(
                          'Send only what you intend to share. Avoid passwords, payment details and sensitive information. Review automatic sending in Settings and add a passphrase for end-to-end encryption. Finishing starts cloud services.',
                        ),
                        CheckboxListTile(
                          contentPadding: EdgeInsets.zero,
                          value: _diagnostics,
                          onChanged: _saving
                              ? null
                              : (value) => setState(
                                  () => _diagnostics = value ?? false,
                                ),
                          title: const Text(
                            'Share crash diagnostics (optional)',
                          ),
                          subtitle: const Text(
                            'Does not include clipboard contents or screenshots.',
                          ),
                        ),
                      ],
                      if (_step == 2 && !_adult) ...[
                        if (!_pending) ...[
                          const Text(
                            'Ask your parent to enter their email. Epic Kids Web Services sends a notice explaining cloud and optional file sync, verifies the adult, and records their choices. Verification may ask your parent for identity information. GhostCopy does not receive those identity documents.',
                          ),
                          const SizedBox(height: 16),
                          TextField(
                            controller: _parentEmail,
                            keyboardType: TextInputType.emailAddress,
                            autocorrect: false,
                            enableSuggestions: false,
                            decoration: const InputDecoration(
                              labelText: 'Parent or guardian email',
                            ),
                          ),
                        ] else
                          const Text(
                            'Check your parent’s email and finish verification there. Then check permission below. This device keeps a secure setup token; no clipboard account has been created yet.',
                          ),
                      ],
                      const SizedBox(height: 24),
                      FilledButton(
                        onPressed: !enabled
                            ? null
                            : _step == 0 && _storeUnasked
                            ? () => unawaited(_askStore())
                            : () => unawaited(_next()),
                        child: Text(
                          _completed
                              ? 'Starting GhostCopy…'
                              : _saving
                              ? 'Please wait…'
                              : _step < 2
                              ? 'Continue'
                              : _adult
                              ? 'Finish setup'
                              : _pending
                              ? 'Check permission'
                              : 'Send parent request',
                        ),
                      ),
                      if (_step == 2 && !_adult && _pending && !_hasAccount)
                        TextButton(
                          onPressed: _saving || _completed
                              ? null
                              : () => unawaited(_restartParentRequest()),
                          child: const Text(
                            'Cancel request and change parent email',
                          ),
                        ),
                    ],
                    if (_error != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: Text(
                          _error!,
                          style: TextStyle(color: GhostColors.errorText),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
