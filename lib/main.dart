import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:hcaptcha/hcaptcha.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:window_manager/window_manager.dart';

import 'repositories/clipboard_repository.dart';
import 'services/auth_service.dart';
import 'services/auto_start_service.dart';
import 'services/clipboard_sync_service.dart';
import 'services/device_service.dart';
import 'services/game_mode_service.dart';
import 'services/hotkey_service.dart';
import 'services/impl/auth_service.dart';
import 'services/impl/clipboard_sync_service.dart';
import 'services/impl/game_mode_service.dart';
import 'services/impl/hotkey_service.dart';
import 'services/impl/lifecycle_controller.dart';
import 'services/impl/notification_service.dart';
import 'services/impl/security_service.dart';
import 'services/impl/toast_window_service.dart';
import 'services/impl/transformer_service.dart';
import 'services/impl/tray_service.dart';
import 'services/impl/window_service.dart';
import 'services/lifecycle_controller.dart';
import 'services/notification_service.dart';
import 'services/push_notification_service.dart';
import 'services/security_service.dart';
import 'services/settings_service.dart';
import 'services/toast_window_service.dart';
import 'services/transformer_service.dart';
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

  // Initialize hCaptcha once at app startup (not per-widget)
  final siteKey = dotenv.env['HCAPTCHA_SITE_KEY'];
  if (siteKey != null && siteKey.isNotEmpty) {
    HCaptcha.init(siteKey: siteKey);
    debugPrint('[App] hCaptcha initialized');
  } else {
    debugPrint('[App] WARNING: hCaptcha site key not found in .env');
  }

  // Initialize Supabase
  await Supabase.initialize(
    url: dotenv.env['SUPABASE_URL'] ?? '',
    anonKey: dotenv.env['SUPABASE_ANON_KEY'] ?? '',
  );

  // Initialize AuthService (handles anonymous sign-in)
  final authService = AuthService();
  await authService.initialize();

  // Initialize DeviceService and register current device
  final deviceService = DeviceService();
  await deviceService.initialize();
  await deviceService.registerCurrentDevice();

  // Initialize services (desktop only)
  if (_isDesktop()) {
    // Create LifecycleController for Sleep Mode management (Task 12.1)
    final lifecycleController = LifecycleController();

    // Initialize services with lifecycle support
    final windowService = WindowService(lifecycleController: lifecycleController);
    final trayService = TrayService();
    final hotkeyService = HotkeyService();
    final gameModeService = GameModeService();
    final toastWindowService = ToastWindowService();
    final notificationService = NotificationService(
      windowService: windowService,
      toastWindowService: toastWindowService,
    );
    final settingsService = SettingsService();
    final autoStartService = AutoStartService();
    final clipboardRepository = ClipboardRepository();

    // Initialize stateless utility services (singletons for consistency)
    final securityService = SecurityService();
    final transformerService = TransformerService();
    final pushNotificationService = PushNotificationService();

    // Initialize background clipboard sync service
    final clipboardSyncService = ClipboardSyncService(
      clipboardRepository: clipboardRepository,
      settingsService: settingsService,
      securityService: securityService,
      pushNotificationService: pushNotificationService,
      notificationService: notificationService,
      gameModeService: gameModeService,
    );

    // Initialize settings service first
    await settingsService.initialize();

    // Initialize toast window service
    await toastWindowService.initialize();

    // Initialize auto-start service
    await autoStartService.initialize();

    // Initialize clipboard sync service (starts realtime subscription and monitoring)
    await clipboardSyncService.initialize();

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
        deviceService: deviceService,
        windowService: windowService,
        trayService: trayService,
        hotkeyService: hotkeyService,
        gameModeService: gameModeService,
        lifecycleController: lifecycleController,
        notificationService: notificationService,
        toastWindowService: toastWindowService,
        settingsService: settingsService,
        autoStartService: autoStartService,
        clipboardRepository: clipboardRepository,
        clipboardSyncService: clipboardSyncService,
        securityService: securityService,
        transformerService: transformerService,
        pushNotificationService: pushNotificationService,
        launchedAtStartup: launchedAtStartup,
      ),
    );
  } else {
    // Mobile app
    runApp(MyApp(
      authService: authService,
      deviceService: deviceService,
    ));
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
    required this.deviceService,
    this.windowService,
    this.trayService,
    this.hotkeyService,
    this.gameModeService,
    this.lifecycleController,
    this.notificationService,
    this.toastWindowService,
    this.settingsService,
    this.autoStartService,
    this.clipboardRepository,
    this.clipboardSyncService,
    this.securityService,
    this.transformerService,
    this.pushNotificationService,
    this.launchedAtStartup = false,
    super.key,
  });

  final IAuthService authService;
  final IDeviceService deviceService;
  final IWindowService? windowService;
  final ITrayService? trayService;
  final IHotkeyService? hotkeyService;
  final IGameModeService? gameModeService;
  final ILifecycleController? lifecycleController;
  final INotificationService? notificationService;
  final IToastWindowService? toastWindowService;
  final ISettingsService? settingsService;
  final IAutoStartService? autoStartService;
  final IClipboardRepository? clipboardRepository;
  final IClipboardSyncService? clipboardSyncService;
  final ISecurityService? securityService;
  final ITransformerService? transformerService;
  final IPushNotificationService? pushNotificationService;
  final bool launchedAtStartup;

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  bool _showingTrayMenu = false;
  bool _openSettingsOnShow = false;
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
      widget.deviceService.dispose();
      widget.notificationService?.dispose();
      widget.toastWindowService?.dispose();
      widget.trayService?.dispose();
      widget.hotkeyService?.dispose();
      widget.gameModeService?.dispose();
      widget.windowService?.dispose();
      widget.lifecycleController?.dispose();
      widget.settingsService?.dispose();
      widget.autoStartService?.dispose();
      widget.clipboardRepository?.dispose();
      widget.clipboardSyncService?.dispose();
      // Note: securityService, transformerService, pushNotificationService
      // are stateless and don't need disposal
    } else {
      // Mobile disposal
      widget.authService.dispose();
      widget.deviceService.dispose();
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

  Future<void> _openSettingsFromTray() async {
    // Set flag to open settings
    setState(() {
      _openSettingsOnShow = true;
      _showingTrayMenu = false;
    });

    // Wait for state to update
    await Future<void>.delayed(const Duration(milliseconds: 100));

    // Show spotlight
    await widget.windowService?.showSpotlight();
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
              onOpenSettings: _openSettingsFromTray,
            )
          : SpotlightScreen(
              authService: widget.authService,
              windowService: widget.windowService!,
              settingsService: widget.settingsService!,
              clipboardRepository: widget.clipboardRepository!,
              clipboardSyncService: widget.clipboardSyncService!,
              securityService: widget.securityService!,
              transformerService: widget.transformerService!,
              pushNotificationService: widget.pushNotificationService!,
              lifecycleController: widget.lifecycleController,
              notificationService: widget.notificationService,
              gameModeService: widget.gameModeService,
              autoStartService: widget.autoStartService,
              hotkeyService: widget.hotkeyService,
              deviceService: widget.deviceService,
              openSettingsOnShow: _openSettingsOnShow,
              onSettingsOpened: () {
                // Reset flag after settings opened
                setState(() => _openSettingsOnShow = false);
              },
            ),
    );
  }
}

// Spotlight screen now imported from ui/screens/spotlight_screen.dart
