import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/settings_service.dart';

/// The saved mobile preference, loaded before the first frame.
final appAppearance = ValueNotifier<AppThemeMode>(AppThemeMode.system);

/// Rebuilds the application when its override or system appearance changes.
class AppearanceBuilder extends StatefulWidget {
  const AppearanceBuilder({required this.builder, super.key});

  final WidgetBuilder builder;

  @override
  State<AppearanceBuilder> createState() => _AppearanceBuilderState();
}

class _AppearanceBuilderState extends State<AppearanceBuilder>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    appAppearance.addListener(_appearanceChanged);
  }

  void _appearanceChanged() => setState(() {});

  @override
  void didChangePlatformBrightness() {
    if (appAppearance.value == AppThemeMode.system) _appearanceChanged();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    appAppearance.removeListener(_appearanceChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context);
}

/// Transparent system bars with glyphs matching the app's brightness.
SystemUiOverlayStyle appearanceOverlayStyle({required bool isLight}) =>
    SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: isLight ? Brightness.dark : Brightness.light,
      statusBarBrightness: isLight ? Brightness.light : Brightness.dark,
      systemNavigationBarColor: Colors.transparent,
      systemNavigationBarIconBrightness: isLight
          ? Brightness.dark
          : Brightness.light,
      systemNavigationBarContrastEnforced: false,
    );
