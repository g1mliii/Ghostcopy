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
import '../theme/app_theme.dart';
import '../theme/appearance.dart';
import '../theme/colors.dart';

/// Runs before cloud, crash-reporting, authentication and clipboard services.
/// Headless processes cannot bypass the first interactive acknowledgement.
Future<void> ensureDistributionConsent({required bool headless}) async {
  final prefs = await loadConsentPreferences();
  final consent = DistributionConsentService(prefs);
  if (consent.isAccepted &&
      prefs.getBool('distribution_cloud_paused') != true) {
    if (consent.ageGroup != DistributionAgeGroup.parentManaged) return;
    try {
      final status = await CloudConsentService.instance.poll();
      if (status['status'] == 'authorized') return;
    } on Exception {
      // The interactive screen lets the parent retry while cloud stays off.
    }
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
        home: DistributionOnboarding(prefs: prefs, onAccepted: ready.complete),
      ),
    ),
  );
  final desktop = Platform.isWindows || Platform.isMacOS || Platform.isLinux;
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
    super.key,
  });
  final SharedPreferences prefs;
  final VoidCallback onAccepted;
  final CloudConsentService? cloud;
  final bool parentAccount;

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
  String? _error;
  final _parentEmail = TextEditingController();
  late final _cloud = widget.cloud ?? CloudConsentService.instance;
  late final IDistributionConsentService _consent = DistributionConsentService(
    widget.prefs,
  );
  late bool _blocked = _consent.isAgeBlocked;

  bool get _adult => _age == '18+';

  @override
  void initState() {
    super.initState();
    _age = widget.prefs.getString('distribution_declared_age');
    if (widget.parentAccount && _age == '18+') _age = null;
    _country = widget.prefs.getString('distribution_declared_country');
    if (_age != null && _country != null && !_adult && !_blocked) {
      unawaited(_restorePending());
    }
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
        await widget.prefs.setString('distribution_declared_age', _age!);
        await widget.prefs.setString(
          'distribution_declared_country',
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
        await widget.prefs.setBool('distribution_cloud_paused', false);
        _finish();
      } else if (!_pending) {
        final result = await _cloud.call(
          'start',
          data: {
            'age': int.parse(_age!),
            'country': _country,
            'parentEmail': _parentEmail.text.trim(),
            'noticeVersion': IDistributionConsentService.version,
            'noticeAcknowledged': true,
          },
        );
        final token = result['claimToken'];
        if (token is! String) {
          throw Exception('Could not start parent verification.');
        }
        await _cloud.saveClaim(token);
        _parentEmail.clear();
        if (mounted) setState(() => _pending = true);
      } else {
        final result = await _cloud.poll();
        if (result['independentEligible'] == true) {
          await widget.prefs.setBool('distribution_graduation_pending', true);
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
                ? 'This request expired. Contact support to restart parent setup.'
                : 'Waiting for your parent to verify and allow cloud sync.',
          );
        }
        await _consent.acceptParentManaged(country: _country!);
        await widget.prefs.setBool('distribution_cloud_paused', false);
        _finish();
      }
    } on Exception catch (error) {
      if (!_adult &&
          error is CloudConsentException &&
          (error.statusCode == 403 || error.statusCode == 404)) {
        _pending = false;
      }
      if (mounted) {
        setState(
          () => _error = error.toString().replaceFirst('Exception: ', ''),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _finish() {
    if (!mounted) return;
    setState(() => _completed = true);
    widget.onAccepted();
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
        (_step == 0 ? _age != null && _country != null : _step != 1 || _agreed);
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
                    else ...[
                      Text(
                        'Step ${_step + 1} of 3',
                        style: TextStyle(color: GhostColors.textSecondary),
                      ),
                      const SizedBox(height: 20),
                      if (_step == 0) ...[
                        const Text(
                          'GhostCopy sends the clips you choose to your linked devices. Cloud services stay off until setup is complete. Tell us your age and country so we can show the right setup. We do not ask for your date of birth.',
                        ),
                        const SizedBox(height: 16),
                        DropdownButtonFormField<String>(
                          initialValue: _age,
                          decoration: const InputDecoration(labelText: 'Age'),
                          items: [
                            for (final age in [
                              'Under 5',
                              for (var i = 5; i < 18; i++) '$i',
                              if (!widget.parentAccount) '18+',
                            ])
                              DropdownMenuItem(value: age, child: Text(age)),
                          ],
                          onChanged:
                              _saving ||
                                  widget.prefs.containsKey(
                                        'distribution_declared_age',
                                      ) &&
                                      widget.prefs.getString(
                                            'distribution_declared_age',
                                          ) ==
                                          _age
                              ? null
                              : (value) => setState(() => _age = value),
                        ),
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
                        onPressed: enabled ? () => unawaited(_next()) : null,
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
