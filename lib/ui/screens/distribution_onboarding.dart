import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../services/distribution_consent_service.dart';
import '../../services/settings_service.dart';
import '../theme/app_theme.dart';
import '../theme/appearance.dart';
import '../theme/colors.dart';

/// Runs before cloud, crash-reporting, authentication and clipboard services.
/// Headless processes cannot bypass the first interactive acknowledgement.
Future<void> ensureDistributionConsent({required bool headless}) async {
  final prefs = await loadConsentPreferences();
  if (DistributionConsentService(prefs).isAccepted) return;
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
  await ready.future;
}

/// Three short setup steps, using the same appearance and tokens as the app.
class DistributionOnboarding extends StatefulWidget {
  const DistributionOnboarding({
    required this.prefs,
    required this.onAccepted,
    super.key,
  });
  final SharedPreferences prefs;
  final VoidCallback onAccepted;

  @override
  State<DistributionOnboarding> createState() => _DistributionOnboardingState();
}

class _DistributionOnboardingState extends State<DistributionOnboarding> {
  int _step = 0;
  String? _age;
  bool _agreed = false;
  bool _parent = false;
  bool _diagnostics = false;
  late final IDistributionConsentService _consent = DistributionConsentService(
    widget.prefs,
  );
  bool _saving = false;
  bool _completed = false;
  String? _error;
  late bool _blocked = _consent.isAgeBlocked;

  Future<void> _next() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      if (_step == 0 && _age == 'Under 16') {
        await _consent.blockAge();
        if (mounted) setState(() => _blocked = true);
      } else if (_step < 2) {
        setState(() => _step++);
      } else {
        await _consent.accept(
          ageGroup: _age == '16–17'
              ? DistributionAgeGroup.teen
              : DistributionAgeGroup.adult,
          guardianAcknowledged: _parent,
          diagnosticsAllowed: _diagnostics,
        );
        if (!mounted) return;
        setState(() => _completed = true);
        widget.onAccepted();
      }
    } on Exception {
      if (mounted) {
        setState(() => _error = 'Could not save setup. Please try again.');
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
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
          () => _error = 'Visit ghostcopy.app/$path to read this policy.',
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final enabled =
        !_saving &&
        !_completed &&
        (_step == 0
            ? _age != null
            : _step != 1 || (_agreed && (_age != '16–17' || _parent)));
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
                      _blocked
                          ? Icons.shield_outlined
                          : Icons.content_copy_rounded,
                      size: 40,
                      color: GhostColors.actionText,
                    ),
                    const SizedBox(height: 24),
                    Text(
                      _blocked
                          ? 'GhostCopy is for ages 16+'
                          : [
                              'Before we begin',
                              'Your choice, clearly',
                              'Know what you sync',
                            ][_step],
                      style: Theme.of(context).textTheme.headlineMedium,
                    ),
                    const SizedBox(height: 12),
                    if (_blocked)
                      const Text(
                        'Cloud setup is unavailable for your age group until verified parental consent is supported. This setup will not create an account or upload clipboard content. If you already have an account, contact support@ghostcopy.app for deletion help.',
                      )
                    else ...[
                      Text(
                        'Step ${_step + 1} of 3',
                        style: TextStyle(color: GhostColors.textSecondary),
                      ),
                      const SizedBox(height: 20),
                      if (_step == 0) ...[
                        const Text(
                          'GhostCopy sends the clips you choose to your linked devices. Cloud services stay off until setup is complete.',
                        ),
                        Wrap(
                          children: [
                            TextButton(
                              onPressed: () => unawaited(_openPolicy('terms')),
                              child: const Text('Terms of service'),
                            ),
                            TextButton(
                              onPressed: () =>
                                  unawaited(_openPolicy('privacy')),
                              child: const Text('Privacy policy'),
                            ),
                          ],
                        ),
                        const Text(
                          'Which age group are you in? We save your eligibility on this device, without collecting your date of birth.',
                        ),
                        const SizedBox(height: 16),
                        DropdownButtonFormField<String>(
                          initialValue: _age,
                          decoration: const InputDecoration(
                            labelText: 'Age group',
                          ),
                          items: [
                            for (final value in ['Under 16', '16–17', '18+'])
                              DropdownMenuItem(
                                value: value,
                                child: Text(value),
                              ),
                          ],
                          onChanged: _saving
                              ? null
                              : (value) => setState(() => _age = value),
                        ),
                      ],
                      if (_step == 1) ...[
                        const Text(
                          'GhostCopy stores the clips you send in your account so your devices can receive them. Account details, device identifiers and crash diagnostics are also processed. Read how storage, retention and deletion work before continuing.',
                        ),
                        Wrap(
                          children: [
                            TextButton(
                              onPressed: () => unawaited(_openPolicy('terms')),
                              child: const Text('Terms of service'),
                            ),
                            TextButton(
                              onPressed: () =>
                                  unawaited(_openPolicy('privacy')),
                              child: const Text('Privacy policy'),
                            ),
                          ],
                        ),
                        CheckboxListTile(
                          contentPadding: EdgeInsets.zero,
                          value: _agreed,
                          onChanged: _saving
                              ? null
                              : (v) => setState(() => _agreed = v ?? false),
                          title: const Text(
                            'I agree to the terms and acknowledge the privacy policy.',
                          ),
                        ),
                        if (_age == '16–17')
                          CheckboxListTile(
                            contentPadding: EdgeInsets.zero,
                            value: _parent,
                            onChanged: _saving
                                ? null
                                : (v) => setState(() => _parent = v ?? false),
                            title: const Text(
                              'My parent or guardian has agreed to my use of GhostCopy.',
                            ),
                          ),
                      ],
                      if (_step == 2) ...[
                        const Text(
                          'Send only what you intend to share with your linked devices. Avoid passwords, payment details and other sensitive clipboard content. Review automatic sending in Settings. A passphrase enables optional end-to-end encryption; without one, synced clips are readable by the service. You can delete clips or your account in Settings.',
                        ),
                        const SizedBox(height: 16),
                        const Text(
                          'Finishing starts cloud services. Crash reporting is optional. Your notice version, age group and acknowledgement time are saved on this device; no date of birth is collected.',
                        ),
                      ],
                      if (_step == 2)
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
                            'Helps fix errors. Does not include clipboard contents or screenshots.',
                          ),
                        ),
                      const SizedBox(height: 24),
                      FilledButton(
                        onPressed: enabled ? () => unawaited(_next()) : null,
                        child: Text(
                          _completed
                              ? 'Starting GhostCopy…'
                              : _saving
                              ? 'Saving…'
                              : _step == 2
                              ? 'Finish setup'
                              : 'Continue',
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
