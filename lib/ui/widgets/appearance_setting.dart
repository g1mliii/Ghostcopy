import 'dart:async';

import 'package:flutter/material.dart';

import '../../services/settings_service.dart';
import '../theme/appearance.dart';

/// Saves and applies the user's mobile appearance preference.
class AppearanceSetting extends StatefulWidget {
  const AppearanceSetting({required this.settings, super.key});

  final ISettingsService settings;

  @override
  State<AppearanceSetting> createState() => _AppearanceSettingState();
}

class _AppearanceSettingState extends State<AppearanceSetting> {
  bool _saving = false;

  Future<void> _selectMode(AppThemeMode mode) async {
    if (_saving || mode == appAppearance.value) return;
    setState(() => _saving = true);
    try {
      await widget.settings.setThemeMode(mode);
      appAppearance.value = mode;
    } on Exception catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Could not save appearance. Try again.'),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<AppThemeMode>(
    valueListenable: appAppearance,
    builder: (context, mode, child) => SegmentedButton<AppThemeMode>(
      segments: const [
        ButtonSegment(value: AppThemeMode.system, label: Text('System')),
        ButtonSegment(value: AppThemeMode.light, label: Text('Light')),
        ButtonSegment(value: AppThemeMode.dark, label: Text('Dark')),
      ],
      selected: {mode},
      onSelectionChanged: _saving
          ? null
          : (selection) => unawaited(_selectMode(selection.single)),
    ),
  );
}
