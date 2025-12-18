import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:window_manager/window_manager.dart';

import 'services/game_mode_service.dart';
import 'services/hotkey_service.dart';
import 'services/impl/game_mode_service.dart';
import 'services/impl/hotkey_service.dart';
import 'services/impl/tray_service.dart';
import 'services/impl/window_service.dart';
import 'services/tray_service.dart';
import 'services/window_service.dart';
import 'ui/theme/app_theme.dart';
import 'ui/widgets/tray_menu_window.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Load environment variables
  await dotenv.load();

  // Initialize Supabase
  await Supabase.initialize(
    url: dotenv.env['SUPABASE_URL'] ?? '',
    anonKey: dotenv.env['SUPABASE_ANON_KEY'] ?? '',
  );

  // Initialize services (desktop only)
  if (_isDesktop()) {
    final windowService = WindowService();
    final trayService = TrayService();
    final hotkeyService = HotkeyService();
    final gameModeService = GameModeService();

    // Initialize window manager with hidden state (Acceptance Criteria #1)
    await windowService.initialize();

    // Initialize system tray (Acceptance Criteria #2)
    await trayService.initialize();

    // Register global hotkey (Requirement 1.1, 3.4)
    // Default: Ctrl+Shift+S to show Spotlight window
    const defaultHotkey = HotKey(key: 's', ctrl: true, shift: true);
    await hotkeyService.registerHotkey(
      defaultHotkey,
      windowService.showSpotlight,
    );

    runApp(
      MyApp(
        windowService: windowService,
        trayService: trayService,
        hotkeyService: hotkeyService,
        gameModeService: gameModeService,
      ),
    );
  } else {
    // Mobile app
    runApp(const MyApp());
  }
}

/// Check if running on desktop platform
bool _isDesktop() {
  return Platform.isWindows || Platform.isMacOS || Platform.isLinux;
}

// Global Supabase client accessor
final supabase = Supabase.instance.client;

class MyApp extends StatefulWidget {
  const MyApp({
    this.windowService,
    this.trayService,
    this.hotkeyService,
    this.gameModeService,
    super.key,
  });

  final IWindowService? windowService;
  final ITrayService? trayService;
  final IHotkeyService? hotkeyService;
  final IGameModeService? gameModeService;

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  bool _showingTrayMenu = false;

  @override
  void initState() {
    super.initState();
    if (_isDesktop()) {
      // Set up tray right-click to show custom menu
      (widget.trayService as TrayService?)?.onRightClick = _showTrayMenu;
    }
  }

  @override
  void dispose() {
    if (_isDesktop()) {
      // Dispose all services to prevent memory leaks
      widget.trayService?.dispose();
      widget.hotkeyService?.dispose();
      widget.gameModeService?.dispose();
      widget.windowService?.dispose();
    }
    super.dispose();
  }

  Future<void> _showTrayMenu() async {
    // Configure window for tray menu (borderless, transparent)
    // Batch operations to reduce lag
    await Future.wait([
      windowManager.setSize(const Size(250, 300)),
      windowManager.setBackgroundColor(Colors.transparent),
      windowManager.setAsFrameless(),
    ]);

    await windowManager.setAlignment(Alignment.bottomRight);
    await windowManager.show();
    await windowManager.focus();

    setState(() => _showingTrayMenu = true);
  }

  void _hideTrayMenu() {
    setState(() => _showingTrayMenu = false);
    widget.windowService?.hideSpotlight();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'GhostCopy',
      theme: AppTheme.darkTheme,
      debugShowCheckedModeBanner: false,
      home: Stack(
        children: [
          SpotlightScreen(windowService: widget.windowService),
          if (_showingTrayMenu)
            TrayMenuWindow(
              windowService: widget.windowService!,
              gameModeService: widget.gameModeService!,
              onClose: _hideTrayMenu,
            ),
        ],
      ),
    );
  }
}

/// Temporary Spotlight screen placeholder
/// This will be replaced with the proper Spotlight UI from ui/screens/spotlight_screen.dart
class SpotlightScreen extends StatefulWidget {
  const SpotlightScreen({this.windowService, super.key});

  final IWindowService? windowService;

  @override
  State<SpotlightScreen> createState() => _SpotlightScreenState();
}

class _SpotlightScreenState extends State<SpotlightScreen> with WindowListener {
  final FocusNode _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    if (_isDesktop()) {
      windowManager.addListener(this);
    }
  }

  @override
  void dispose() {
    if (_isDesktop()) {
      windowManager.removeListener(this);
    }
    _focusNode.dispose();
    super.dispose();
  }

  @override
  void onWindowFocus() {
    // Request focus when window gains focus
    _focusNode.requestFocus();
  }

  @override
  void onWindowBlur() {
    // Hide window when it loses focus (user clicks outside)
    widget.windowService?.hideSpotlight();
  }

  @override
  Widget build(BuildContext context) {
    return KeyboardListener(
      focusNode: _focusNode,
      autofocus: true,
      onKeyEvent: (event) {
        if (event is KeyDownEvent &&
            event.logicalKey == LogicalKeyboardKey.escape) {
          // Hide on Escape key
          widget.windowService?.hideSpotlight();
        }
      },
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: Center(
          child: Container(
            width: 500,
            height: 400,
            decoration: BoxDecoration(
              color: const Color(0xFF1A1A1D),
              borderRadius: BorderRadius.circular(12),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.5),
                  blurRadius: 20,
                  spreadRadius: 5,
                ),
              ],
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(
                  Icons.content_copy,
                  size: 64,
                  color: Color(0xFF5865F2),
                ),
                const SizedBox(height: 16),
                Text(
                  'GhostCopy Spotlight',
                  style: Theme.of(
                    context,
                  ).textTheme.headlineMedium?.copyWith(color: Colors.white),
                ),
                const SizedBox(height: 8),
                Text(
                  'Press Escape to close',
                  style: Theme.of(
                    context,
                  ).textTheme.bodyMedium?.copyWith(color: Colors.white70),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
