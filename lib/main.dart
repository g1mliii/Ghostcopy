import 'dart:io';

import 'package:flutter/material.dart';
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
import 'ui/screens/spotlight_screen.dart';
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

  // Sign in anonymously for testing (auth features will be added later)
  try {
    final currentUser = Supabase.instance.client.auth.currentUser;
    if (currentUser == null) {
      await Supabase.instance.client.auth.signInAnonymously();
      debugPrint('Signed in anonymously');
    } else {
      debugPrint('Already signed in as: ${currentUser.id}');
    }
  } on Exception catch (e) {
    debugPrint('Failed to sign in anonymously: $e');
  }

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
    // Note: We'll set the callback in MyApp since it needs state access

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

      // Register global hotkey with state-aware callback
      const defaultHotkey = HotKey(key: 's', ctrl: true, shift: true);
      widget.hotkeyService?.registerHotkey(
        defaultHotkey,
        _handleHotkeySpotlight,
      );
    }
  }

  /// Handle Ctrl+Shift+S hotkey - ensures correct state before showing
  Future<void> _handleHotkeySpotlight() async {
    // Always ensure tray menu state is false
    if (_showingTrayMenu) {
      setState(() => _showingTrayMenu = false);
      // Wait for state to update and tray to close
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }

    // Now show spotlight
    await widget.windowService?.showSpotlight();
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
    // Hide window first to prevent warping during resize
    await windowManager.hide();

    // Update state so correct widget (TrayMenuWindow) will render
    setState(() => _showingTrayMenu = true);

    // Give a frame for state to update
    await Future<void>.delayed(
      const Duration(milliseconds: 16),
    ); // One frame at 60fps

    // Configure window for tray menu
    await windowManager.setSize(const Size(250, 300));
    await windowManager.setBackgroundColor(Colors.transparent);
    await windowManager.setAsFrameless();

    // Wait for resize to complete
    await Future<void>.delayed(const Duration(milliseconds: 50));

    // Position menu above taskbar at bottom-right
    // Use Alignment to position, but we'll use topRight anchored to bottom
    // This positions it in bottom-right area but the menu extends upward
    await windowManager.setAlignment(Alignment.bottomRight);

    // Show with correct size and content
    await windowManager.show();
    await windowManager.focus();
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
      home: _showingTrayMenu
          ? TrayMenuWindow(
              windowService: widget.windowService!,
              gameModeService: widget.gameModeService!,
              onClose: _hideTrayMenu,
            )
          : SpotlightScreen(windowService: widget.windowService!),
    );
  }
}

// Spotlight screen now imported from ui/screens/spotlight_screen.dart
