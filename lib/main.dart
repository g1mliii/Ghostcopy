import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:window_manager/window_manager.dart';

import 'locator.dart';
import 'repositories/clipboard_repository.dart';
import 'services/auth_service.dart';
import 'services/auto_start_service.dart';
import 'services/clipboard_sync_service.dart';
import 'services/device_service.dart';
import 'services/fcm_service.dart';
import 'services/game_mode_service.dart';
import 'services/hotkey_service.dart';
import 'services/impl/auth_service.dart';
import 'services/impl/clipboard_sync_service.dart';
import 'services/impl/game_mode_service.dart';
import 'services/impl/hotkey_service.dart';
import 'services/impl/lifecycle_controller.dart';
import 'services/impl/notification_service.dart';
import 'services/impl/security_service.dart';
import 'services/impl/system_power_service.dart';
import 'services/impl/transformer_service.dart';
import 'services/impl/tray_service.dart';
import 'services/impl/window_service.dart';
import 'services/lifecycle_controller.dart';
import 'services/notification_service.dart';
import 'services/obsidian_service.dart';
import 'services/push_notification_service.dart';
import 'services/security_service.dart';
import 'services/settings_service.dart';
import 'services/system_power_service.dart';
import 'services/temp_file_service.dart';
import 'services/transformer_service.dart';
import 'services/tray_service.dart';
import 'services/url_shortener_service.dart';
import 'services/webhook_service.dart';
import 'services/widget_service.dart';
import 'services/window_service.dart';
import 'ui/screens/mobile_main_screen.dart';
import 'ui/screens/mobile_welcome_screen.dart';
import 'ui/screens/spotlight_screen.dart';
import 'ui/theme/app_theme.dart';
import 'ui/viewmodels/spotlight_viewmodel.dart';
import 'ui/widgets/tray_menu_window.dart';

// Configuration - These values are safe to be public
// Security comes from Supabase Row-Level Security (RLS) policies, not hiding these keys
const _supabaseUrl = 'https://xhbggxftvnlkotvehwmj.supabase.co';
const _supabaseAnonKey =
    'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InhoYmdneGZ0dm5sa290dmVod21qIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NjQxOTk5MTIsImV4cCI6MjA3OTc3NTkxMn0.4xCsBo1ztgnrlGgJM8j78VWHpdp1bAjuHkgVD00HQXA';

/// Top-level background message handler for Firebase Cloud Messaging.
/// This handles notifications when the app is terminated or in background.
@pragma('vm:entry-point')
Future<void> _firebaseBackgroundHandler(RemoteMessage message) async {
  debugPrint('[FCM Background] Received message: ${message.messageId}');

  // For background, we don't do anything - Firebase plugin handles notification display
  // The notification tap will be handled when app comes to foreground
}

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();

  // Suppress RawKeyboard assertion errors on Windows (known Flutter issue)
  // This occurs when Windows sends key events with invalid modifier flags
  // The assertion doesn't affect functionality - it's just noisy debug output
  // See: https://github.com/flutter/flutter/issues/93594
  if (Platform.isWindows) {
    FlutterError.onError = (details) {
      // Suppress known RawKeyboard assertion on Windows
      if (details.exception is AssertionError &&
          details.exception.toString().contains('RawKeyDownEvent') &&
          details.exception.toString().contains('_keysPressed.isNotEmpty')) {
        debugPrint(
          '[Main] ⚠️ Suppressed RawKeyboard assertion (known Windows issue)',
        );
        return;
      }
      // Log other errors normally
      FlutterError.presentError(details);
    };
  }

  // Check if app was launched at startup (for hidden mode)
  final launchedAtStartup = args.contains('--launched-at-startup');

  // Start periodic cleanup timer (every 15 minutes)
  TempFileService.instance.startPeriodicCleanup();

  // PARALLEL GROUP 1: Independent startup operations
  await Future.wait([
    // Cleanup old temp files from previous sessions
    TempFileService.instance.cleanupTempFiles(),

    // Initialize Supabase with session persistence
    Supabase.initialize(url: _supabaseUrl, anonKey: _supabaseAnonKey),

    // Register custom URL scheme for OAuth callbacks (Windows only)
    if (Platform.isWindows)
      _registerWindowsUrlScheme()
    else
      Future<void>.value(),
  ]);

  // Initialize services that depend on Supabase
  final authService = AuthService();
  final deviceService = DeviceService();

  locator
    ..registerSingleton<IAuthService>(authService)
    ..registerSingleton<IDeviceService>(deviceService);

  // PARALLEL GROUP 2: Auth and Device initialization (both depend on Supabase)
  if (_isDesktop()) {
    await Future.wait([authService.initialize(), deviceService.initialize()]);
  } else {
    // Mobile: Only initialize device service
    await deviceService.initialize();
  }

  // For desktop: Register device immediately
  // For mobile: Skip registration - welcome screen will handle it after auth
  if (_isDesktop()) {
    await deviceService.registerCurrentDevice();
  }

  // Initialize services (desktop only)
  if (_isDesktop()) {
    // Initialize core services first
    final trayService = TrayService();
    final hotkeyService = HotkeyService();
    final gameModeService = GameModeService();
    final settingsService = SettingsService();
    final autoStartService = AutoStartService();
    final clipboardRepository = ClipboardRepository.instance;

    // Register generic services
    locator
      ..registerSingleton<ITrayService>(trayService)
      ..registerSingleton<IHotkeyService>(hotkeyService)
      ..registerSingleton<IGameModeService>(gameModeService)
      ..registerSingleton<ISettingsService>(settingsService)
      ..registerSingleton<IAutoStartService>(autoStartService)
      ..registerSingleton<IClipboardRepository>(clipboardRepository);

    // Initialize stateless utility services (singletons for consistency)
    final securityService = SecurityService();
    final transformerService = TransformerService();
    final pushNotificationService = PushNotificationService();
    final urlShortenerService = UrlShortenerService();
    final webhookService = WebhookService();
    final obsidianService = ObsidianService();

    // Register stateless utility services
    locator
      ..registerSingleton<ISecurityService>(securityService)
      ..registerSingleton<ITransformerService>(transformerService)
      ..registerSingleton<IPushNotificationService>(pushNotificationService)
      ..registerSingleton<IUrlShortenerService>(urlShortenerService)
      ..registerSingleton<IWebhookService>(webhookService)
      ..registerSingleton<IObsidianService>(obsidianService);

    // Initialize settings service first (required by other services)
    await settingsService.initialize();

    // Initialize background clipboard sync service
    final clipboardSyncService = ClipboardSyncService(
      clipboardRepository: clipboardRepository,
      settingsService: settingsService,
      securityService: securityService,
      gameModeService: gameModeService,
      urlShortenerService: urlShortenerService,
      webhookService: webhookService,
      obsidianService: obsidianService,
    );

    // PARALLEL GROUP 3: ClipboardSync and SystemPower (independent)
    final systemPowerService = SystemPowerService();
    await Future.wait([
      clipboardSyncService.initialize(),
      systemPowerService.initialize(),
    ]);

    locator
      ..registerSingleton<IClipboardSyncService>(clipboardSyncService)
      ..registerSingleton<ISystemPowerService>(systemPowerService);

    // Create LifecycleController for Tray Mode and connection management
    // Must be created AFTER clipboardSyncService and settingsService
    final lifecycleController = LifecycleController(
      clipboardSyncService: clipboardSyncService,
      settingsService: settingsService,
    );
    locator.registerSingleton<ILifecycleController>(lifecycleController);

    // Initialize lifecycle controller (loads feature flags, starts monitoring)
    await lifecycleController.initialize();

    // Note: Power event stream subscription is set up in MyApp.initState()
    // to ensure it can be properly cancelled in dispose()

    // Initialize services with lifecycle support
    final windowService = WindowService(
      lifecycleController: lifecycleController,
    );
    locator.registerSingleton<IWindowService>(windowService);
    final notificationService = NotificationService(
      windowService: windowService,
      gameModeService: gameModeService,
    );
    locator.registerSingleton<INotificationService>(notificationService);

    // Note: ClipboardSyncService was initialized with notificationService: null
    // This is okay - the service will just skip notifications if null

    // Register ViewModels and other factories
    setupLocator();

    // PARALLEL GROUP 4: Independent UI services
    await Future.wait([
      autoStartService.initialize(),
      windowService.initialize(),
      trayService.initialize(),
    ]);

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

    // Register global hotkey (Requirement 1.1, 3.4)
    // Default: Ctrl+Shift+S to show Spotlight window
    // Note: We'll set the callback in MyApp since it needs state access

    runApp(MyApp(launchedAtStartup: launchedAtStartup));
  } else {
    // Mobile app - initialize Firebase and FCM (optional)
    FcmService? fcmService;
    String? fcmToken;
    // ignore: cancel_subscriptions - Subscriptions are cancelled in MyApp.dispose()
    StreamSubscription<String>? tokenRefreshSubscription;
    // ignore: cancel_subscriptions - Subscriptions are cancelled in MyApp.dispose()
    StreamSubscription<RemoteMessage>? foregroundMessageSubscription;
    // ignore: cancel_subscriptions - Subscriptions are cancelled in MyApp.dispose()
    StreamSubscription<RemoteMessage>? messageOpenedAppSubscription;

    // Initialize Settings Service (needed for clipboard auto-clear and other settings)
    final settingsService = SettingsService();
    await settingsService.initialize();
    debugPrint('[App] ✅ Settings service initialized for mobile');
    locator.registerSingleton<ISettingsService>(settingsService);

    try {
      await Firebase.initializeApp();
      debugPrint('[App] ✅ Firebase initialized for mobile');

      // Register background message handler (must be before other FCM setup)
      FirebaseMessaging.onBackgroundMessage(_firebaseBackgroundHandler);
      debugPrint('[App] ✅ Firebase background message handler registered');

      // Initialize FCM service for push notifications
      fcmService = FcmService();
      await fcmService.initialize();

      // Initialize widget service (singleton) for home screen widgets
      final widgetService = WidgetService();
      await widgetService.initialize();
      debugPrint('[App] ✅ Widget service initialized');
      locator
        ..registerSingleton<IFcmService>(fcmService)
        ..registerSingleton<IWidgetService>(widgetService)
        // Register other mobile services
        ..registerSingleton<IClipboardRepository>(ClipboardRepository.instance)
        ..registerSingleton<ISecurityService>(SecurityService())
        ..registerSingleton<ITransformerService>(TransformerService());

      // Configure Android notification channel for clipboard sync
      if (Platform.isAndroid) {
        final channel = AndroidNotificationChannel(
          'clipboard_sync', // Channel ID
          'Clipboard Sync', // Channel name
          description: 'Notifications for clipboard synchronization',
          importance:
              Importance.high, // High importance for heads-up notifications
          playSound: false, // Silent for invisible sync (adjust if needed)
          enableVibration:
              false, // No vibration for invisible sync (adjust if needed)
        );

        final flutterLocalNotificationsPlugin =
            FlutterLocalNotificationsPlugin();

        await flutterLocalNotificationsPlugin
            .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin
            >()
            ?.createNotificationChannel(channel);

        debugPrint(
          '[App] ✅ Android notification channel created: clipboard_sync',
        );
      }

      // Get FCM token and update device
      fcmToken = await fcmService.getToken();
      if (fcmToken != null) {
        debugPrint(
          '[App] Got FCM token, will update device after registration',
        );
      }

      // Listen for token refresh and update device (store subscription for cleanup)
      tokenRefreshSubscription = fcmService.tokenRefreshStream.listen((
        newToken,
      ) async {
        debugPrint('[App] 🔄 FCM token refreshed, updating device...');
        await deviceService.updateFcmToken(newToken);
      });

      // Handle foreground messages (when app is running) - store subscription
      foregroundMessageSubscription = FirebaseMessaging.onMessage.listen((
        message,
      ) {
        debugPrint('[FCM Foreground] Received message: ${message.messageId}');

        final clipboardContent =
            (message.data['clipboard_content'] as String?) ?? '';
        final deviceType =
            (message.data['device_type'] as String?) ?? 'Another device';

        if (clipboardContent.isNotEmpty) {
          debugPrint(
            '[FCM Foreground] Auto-copying content from $deviceType to clipboard',
          );
          // In foreground, we can copy directly to clipboard
          // (Note: In background, Android native service handles it)
        }
      });

      // Handle notification tap (when app is in background or terminated) - store subscription
      messageOpenedAppSubscription = FirebaseMessaging.onMessageOpenedApp
          .listen((message) {
            debugPrint('[FCM Tap] Notification tapped: ${message.messageId}');

            final clipboardContent =
                (message.data['clipboard_content'] as String?) ?? '';
            if (clipboardContent.isNotEmpty) {
              debugPrint(
                '[FCM Tap] Handling notification tap with clipboard content',
              );
              // Content already copied by CopyActivity or native handler
            }
          });
    } on Exception catch (e) {
      debugPrint(
        '[App] ⚠️  Firebase initialization skipped (not configured): $e',
      );
      debugPrint(
        '[App] Push notifications will not work until Firebase is configured',
      );
    }

    runApp(
      MyApp(
        fcmToken: fcmToken,
        tokenRefreshSubscription: tokenRefreshSubscription,
        foregroundMessageSubscription: foregroundMessageSubscription,
        messageOpenedAppSubscription: messageOpenedAppSubscription,
      ),
    );
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
    this.fcmToken,
    this.tokenRefreshSubscription,
    this.foregroundMessageSubscription,
    this.messageOpenedAppSubscription,
    this.launchedAtStartup = false,
    super.key,
  });

  final String? fcmToken;
  final StreamSubscription<String>? tokenRefreshSubscription;
  final StreamSubscription<RemoteMessage>? foregroundMessageSubscription;
  final StreamSubscription<RemoteMessage>? messageOpenedAppSubscription;
  final bool launchedAtStartup;

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  bool _showingTrayMenu = false;
  bool _openSettingsOnShow = false;
  bool _mobileAuthComplete = false;
  bool _servicesDisposed = false;
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();
  StreamSubscription<PowerEvent>? _powerEventSubscription;

  // Lazy-initialized mobile services (created once, not on every build)
  // Removed: now registered in main()

  @override
  void initState() {
    super.initState();
    if (_isDesktop()) {
      // Initialize notification service with navigator key
      locator<INotificationService>().initialize(_navigatorKey);

      // Warm up shaders to reduce UI jank on first animations
      // This precompiles common shaders used in the app
      WidgetsBinding.instance.addPostFrameCallback((_) {
        debugPrint('[Main] Warming up shaders and precaching icons...');

        // Shader warmup
        final recorder = PictureRecorder();
        final canvas = Canvas(recorder);
        final paint = Paint()..color = Colors.white;

        // Warm up common shader operations used in app
        canvas
          ..drawRect(const Rect.fromLTWH(0, 0, 100, 100), paint) // Rectangles
          ..drawRRect(
            RRect.fromRectAndRadius(
              const Rect.fromLTWH(0, 0, 100, 100),
              const Radius.circular(12),
            ),
            paint,
          ); // Rounded corners
        paint.maskFilter = const MaskFilter.blur(
          BlurStyle.normal,
          10,
        ); // Blur effects
        canvas.drawRect(const Rect.fromLTWH(0, 0, 100, 100), paint);
        recorder.endRecording().dispose();

        debugPrint('[Main] ✅ Shader warmup complete');

        // Precache common icons
        _precacheCommonIcons();
      });

      // Wire up Game Mode notification callback (Requirement 6.3)
      locator<IGameModeService>().setNotificationCallback((item) {
        locator<INotificationService>().showClipboardNotification(
          content: item.content,
          deviceType: item.deviceType,
        );
      });

      // Wire up power events to lifecycle controller
      _powerEventSubscription = locator<ISystemPowerService>().powerEventStream
          .listen((event) {
            debugPrint('[Main] 🔌 Power event: ${event.type.name}');

            switch (event.type) {
              case PowerEventType.systemSleep:
                locator<ILifecycleController>().onSystemSleep();
                break;
              case PowerEventType.systemWake:
                locator<ILifecycleController>().onSystemWake();
                break;
              case PowerEventType.screenLock:
                locator<ILifecycleController>().onScreenLock();
                break;
              case PowerEventType.screenUnlock:
                locator<ILifecycleController>().onScreenUnlock();
                break;
            }
          });

      // Set up tray right-click to show custom menu
      (locator<ITrayService>() as TrayService).onRightClick = _showTrayMenu;

      // Register global hotkey with state-aware callback
      const defaultHotkey = HotKey(key: 's', ctrl: true, shift: true);
      locator<IHotkeyService>().registerHotkey(
        defaultHotkey,
        _handleHotkeySpotlight,
      );
    } else {
      // Mobile: Check if user is already signed in
      final currentUser = locator<IAuthService>().currentUser;
      if (currentUser != null && !currentUser.isAnonymous) {
        // User is already authenticated, skip welcome screen
        _mobileAuthComplete = true;
        debugPrint('[Mobile] User already signed in, skipping welcome screen');
      }
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
    await locator<IWindowService>().showSpotlight();
  }

  /// Precache frequently used Material Icons to prevent first-frame jank
  /// This renders common icons to warm up the icon font cache
  void _precacheCommonIcons() {
    // List of commonly used icons in the app
    final commonIcons = [
      Icons.content_copy, // Copy icon (used throughout)
      Icons.send_rounded, // Send button
      Icons.settings_outlined, // Settings panel
      Icons.devices, // Device management
      Icons.check_circle, // Success states
      Icons.error_outline, // Error states
      Icons.close, // Close buttons
      Icons.search, // Search functionality
      Icons.delete_outline, // Delete actions
      Icons.visibility, // Show/hide toggles
      Icons.visibility_off, // Show/hide toggles
      Icons.lock, // Encryption
      Icons.lock_open, // Encryption
      Icons.history, // History
      Icons.refresh, // Refresh actions
      Icons.more_vert, // More options
    ];

    // Create a temporary canvas and paint to render icons
    // This forces Flutter to load and cache the icon glyphs
    final recorder = PictureRecorder();
    final canvas = Canvas(recorder);

    for (final icon in commonIcons) {
      // Create, use, and dispose TextPainter to prevent memory leak
      TextPainter(
          text: TextSpan(
            text: String.fromCharCode(icon.codePoint),
            style: TextStyle(
              fontFamily: icon.fontFamily,
              fontSize: 24,
              color: Colors.white,
            ),
          ),
          textDirection: TextDirection.ltr,
        )
        ..layout()
        ..paint(canvas, Offset.zero)
        ..dispose();
    }

    // End recording and dispose picture to prevent memory leak
    recorder.endRecording().dispose();

    debugPrint('[Main] ✅ Precached ${commonIcons.length} common icons');
  }

  @override
  void dispose() {
    _disposeServices();
    super.dispose();
  }

  void _disposeServices() {
    if (_servicesDisposed) return;
    _servicesDisposed = true;

    if (_isDesktop()) {
      // Cancel stream subscription to prevent memory leaks
      _powerEventSubscription?.cancel();
      _powerEventSubscription = null;

      // Dispose all services to prevent memory leaks
      locator<IAuthService>().dispose();
      locator<IDeviceService>().dispose();
      locator<INotificationService>().dispose();
      locator<ITrayService>().dispose();
      locator<IHotkeyService>().dispose();
      locator<IGameModeService>().dispose();
      locator<IWindowService>().dispose();
      locator<ILifecycleController>().dispose();
      locator<ISettingsService>().dispose();
      locator<IAutoStartService>().dispose();
      // NOTE: ClipboardRepository is a singleton - dispose is a no-op now
      locator<IClipboardRepository>().dispose();
      locator<IClipboardSyncService>().dispose();
      locator<IUrlShortenerService>().dispose();
      locator<IWebhookService>().dispose();
      locator<IObsidianService>().dispose();
      locator<ISystemPowerService>().dispose();

      // Dispose singleton ViewModel
      // Note: We don't register it by interface so we access concrete class
      try {
        locator<SpotlightViewModel>().dispose();
      } on Object catch (_) {
        // Ignore if not initialized
      }
      // Note: securityService, transformerService, pushNotificationService
      // are stateless and don't need disposal
    } else {
      // Mobile disposal

      // Cancel FCM stream subscriptions to prevent memory leaks
      widget.tokenRefreshSubscription?.cancel();
      widget.foregroundMessageSubscription?.cancel();
      widget.messageOpenedAppSubscription?.cancel();

      locator<IAuthService>().dispose();
      locator<IDeviceService>().dispose();
      locator<IFcmService>().dispose();

      // Dispose widget service (singleton) to clean up method channel
      locator<IWidgetService>().dispose();
    }

    // Stop temp file cleanup timer (cross-platform)
    TempFileService.instance.stopPeriodicCleanup();
  }

  Future<void> _handleQuit() async {
    debugPrint('[App] 🛑 Quit requested - starting cleanup...');
    _disposeServices();
    debugPrint('[App] ✅ Manual cleanup complete');
    await windowManager.destroy();
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
    // Increase size to handling overflow issues on different DPIs
    await windowManager.setSize(const Size(320, 450));
    await windowManager.setBackgroundColor(Colors.transparent);
    await windowManager.setAsFrameless();

    // macOS-specific: Set window to be transparent and ignore mouse events on transparent areas
    if (Platform.isMacOS) {
      await windowManager.setHasShadow(false); // Remove default window shadow
    }

    // Wait for resize to complete
    await Future<void>.delayed(const Duration(milliseconds: 50));

    // Position menu based on platform:
    // - macOS: Top-right (menu bar is at top)
    // - Windows: Bottom-right (taskbar is at bottom)
    if (Platform.isMacOS) {
      await windowManager.setAlignment(Alignment.topRight);
    } else {
      await windowManager.setAlignment(Alignment.bottomRight);
    }

    // Show with correct size and content
    await windowManager.show();
    await windowManager.focus();
  }

  void _hideTrayMenu() {
    setState(() => _showingTrayMenu = false);
    locator<IWindowService>().hideSpotlight();

    // Test toast notification when minimizing to tray (with delay to ensure window is hidden)
    Future.delayed(const Duration(milliseconds: 500), () {
      locator<INotificationService>().showToast(
        message: 'App closed to tray',
        duration: const Duration(seconds: 3),
      );
    });
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
    await locator<IWindowService>().showSpotlight();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: _navigatorKey,
      title: 'GhostCopy',
      theme: AppTheme.darkTheme,
      debugShowCheckedModeBanner: false,
      home: _buildHome(),
    );
  }

  Widget _buildHome() {
    // Desktop app
    if (_isDesktop()) {
      return _showingTrayMenu
          ? TrayMenuWindow(
              windowService: locator<IWindowService>(),
              gameModeService: locator<IGameModeService>(),
              onClose: _hideTrayMenu,
              onOpenSettings: _openSettingsFromTray,
              onQuit: _handleQuit,
            )
          : SpotlightScreen(
              openSettingsOnShow: _openSettingsOnShow,
              onSettingsOpened: () {
                // Reset flag after settings opened
                setState(() => _openSettingsOnShow = false);
              },
            );
    }

    // Mobile app - show welcome screen or main screen based on auth state
    if (!_mobileAuthComplete) {
      return MobileWelcomeScreen(
        fcmToken: widget.fcmToken,
        onAuthComplete: () async {
          // Register device with FCM token after auth
          await locator<IDeviceService>().registerCurrentDevice();

          // Update FCM token if available
          if (widget.fcmToken != null) {
            await locator<IDeviceService>().updateFcmToken(widget.fcmToken!);
            debugPrint('[Mobile] ✅ Device registered with FCM token');
          }

          // Navigate to main mobile UI
          debugPrint('[Mobile] Auth complete, showing main UI');
          setState(() {
            _mobileAuthComplete = true;
          });
        },
      );
    }

    // Mobile main screen - show after auth complete
    return const MobileMainScreen();
  }
}

/// Register ghostcopy:// URL scheme in Windows Registry for OAuth callbacks
Future<void> _registerWindowsUrlScheme() async {
  try {
    // Get the executable path
    final exePath = Platform.resolvedExecutable;

    // Register the URL protocol in Windows Registry
    // This allows ghostcopy:// links to open the app
    await Process.run('reg', [
      'add',
      r'HKCU\Software\Classes\ghostcopy',
      '/ve',
      '/d',
      'URL:GhostCopy Protocol',
      '/f',
    ]);

    await Process.run('reg', [
      'add',
      r'HKCU\Software\Classes\ghostcopy',
      '/v',
      'URL Protocol',
      '/d',
      '',
      '/f',
    ]);

    await Process.run('reg', [
      'add',
      r'HKCU\Software\Classes\ghostcopy\shell\open\command',
      '/ve',
      '/d',
      '"$exePath" "%1"',
      '/f',
    ]);

    debugPrint(
      '[Main] ✅ Registered ghostcopy:// URL scheme in Windows Registry',
    );
  } on Exception catch (e) {
    debugPrint('[Main] ⚠️ Failed to register URL scheme: $e');
    // Non-fatal - continue app startup
  }
}

// Spotlight screen now imported from ui/screens/spotlight_screen.dart
