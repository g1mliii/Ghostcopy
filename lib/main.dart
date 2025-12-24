import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:window_manager/window_manager.dart';

import 'services/auth_service.dart';
import 'services/auto_start_service.dart';
import 'services/game_mode_service.dart';
import 'services/hotkey_service.dart';
import 'services/impl/auth_service.dart';
import 'services/impl/game_mode_service.dart';
import 'services/impl/hotkey_service.dart';
import 'services/impl/lifecycle_controller.dart';
import 'services/impl/notification_service.dart';
import 'services/impl/tray_service.dart';
import 'services/impl/window_service.dart';
import 'services/lifecycle_controller.dart';
import 'services/notification_service.dart';
import 'services/settings_service.dart';
import 'services/tray_service.dart';
import 'services/window_service.dart';
import 'ui/screens/spotlight_screen.dart';
import 'ui/theme/app_theme.dart';
import 'ui/widgets/tray_menu_window.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();

  // Check if app was launched at startup (for hidden mode)
  final launchedAtStartup = args.contains('--launched-at-startup');

  // Load environment variables
  await dotenv.load();

  // Initialize Supabase
  await Supabase.initialize(
    url: dotenv.env['SUPABASE_URL'] ?? '',
    anonKey: dotenv.env['SUPABASE_ANON_KEY'] ?? '',
  );

  // Initialize AuthService (handles anonymous sign-in)
  final authService = AuthService();
  await authService.initialize();

  // Initialize services (desktop only)
  if (_isDesktop()) {
    // Create LifecycleController for Sleep Mode management (Task 12.1)
    final lifecycleController = LifecycleController();

    // Initialize services with lifecycle support
    final windowService = WindowService(lifecycleController: lifecycleController);
    final trayService = TrayService();
    final hotkeyService = HotkeyService();
    final gameModeService = GameModeService();
    final notificationService = NotificationService();
    final settingsService = SettingsService();
    final autoStartService = AutoStartService();

    // Initialize settings service first
    await settingsService.initialize();

    // Initialize auto-start service
    await autoStartService.initialize();

    // Sync auto-start setting with system if needed
    final autoStartEnabled = await settingsService.getAutoStartEnabled();
    final systemAutoStartEnabled = await autoStartService.isEnabled();
    if (autoStartEnabled != systemAutoStartEnabled) {
      // Sync setting with actual system state
      if (autoStartEnabled) {
        await autoStartService.enable();
      } else {
        await autoStartService.disable();
      }
    }

    // Initialize window manager with hidden state (Acceptance Criteria #1)
    // Note: App always starts hidden, regardless of launch method
    await windowService.initialize();

    // Initialize system tray (Acceptance Criteria #2)
    await trayService.initialize();

    // Register global hotkey (Requirement 1.1, 3.4)
    // Default: Ctrl+Shift+S to show Spotlight window
    // Note: We'll set the callback in MyApp since it needs state access

    runApp(
      MyApp(
        authService: authService,
        windowService: windowService,
        trayService: trayService,
        hotkeyService: hotkeyService,
        gameModeService: gameModeService,
        lifecycleController: lifecycleController,
        notificationService: notificationService,
        settingsService: settingsService,
        autoStartService: autoStartService,
        launchedAtStartup: launchedAtStartup,
      ),
    );
  } else {
    // Mobile app
    runApp(MyApp(authService: authService));
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
    required this.authService,
    this.windowService,
    this.trayService,
    this.hotkeyService,
    this.gameModeService,
    this.lifecycleController,
    this.notificationService,
    this.settingsService,
    this.autoStartService,
    this.launchedAtStartup = false,
    super.key,
  });

  final IAuthService authService;
  final IWindowService? windowService;
  final ITrayService? trayService;
  final IHotkeyService? hotkeyService;
  final IGameModeService? gameModeService;
  final ILifecycleController? lifecycleController;
  final INotificationService? notificationService;
  final ISettingsService? settingsService;
  final IAutoStartService? autoStartService;
  final bool launchedAtStartup;

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  bool _showingTrayMenu = false;
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();

  @override
  void initState() {
    super.initState();
    if (_isDesktop()) {
      // Initialize notification service with navigator key
      widget.notificationService?.initialize(_navigatorKey);

      // Wire up Game Mode notification callback (Requirement 6.3)
      widget.gameModeService?.setNotificationCallback((item) {
        widget.notificationService?.showClipboardNotification(
          content: item.content,
          deviceType: item.deviceType,
        );
      });

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
      widget.authService.dispose();
      widget.notificationService?.dispose();
      widget.trayService?.dispose();
      widget.hotkeyService?.dispose();
      widget.gameModeService?.dispose();
      widget.windowService?.dispose();
      widget.lifecycleController?.dispose();
      widget.settingsService?.dispose();
      widget.autoStartService?.dispose();
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
      navigatorKey: _navigatorKey,
      title: 'GhostCopy',
      theme: AppTheme.darkTheme,
      debugShowCheckedModeBanner: false,
      home: _showingTrayMenu
          ? TrayMenuWindow(
              windowService: widget.windowService!,
              gameModeService: widget.gameModeService!,
              onClose: _hideTrayMenu,
            )
          : SpotlightScreen(
              authService: widget.authService,
              windowService: widget.windowService!,
              lifecycleController: widget.lifecycleController,
              notificationService: widget.notificationService,
              gameModeService: widget.gameModeService,
            ),
    );
  }
}

// Spotlight screen now imported from ui/screens/spotlight_screen.dart
