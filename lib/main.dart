import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:path_provider/path_provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:window_manager/window_manager.dart';

import 'locator.dart';
import 'models/clipboard_item.dart';
import 'models/clipboard_limits.dart';
import 'repositories/clipboard_repository.dart';
import 'services/auth_service.dart';
import 'services/auto_start_service.dart';
import 'services/clipboard_sync_service.dart';
import 'services/device_service.dart';
import 'services/fcm_service.dart';
import 'services/file_type_service.dart';
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
import 'services/single_instance.dart';
import 'services/system_power_service.dart';
import 'services/temp_file_service.dart';
import 'services/transformer_service.dart';
import 'services/tray_service.dart';
import 'services/url_shortener_service.dart';
import 'services/webhook_service.dart';
import 'services/window_service.dart';
import 'ui/platform_adaptive.dart';
import 'ui/screens/mobile_main_screen.dart';
import 'ui/screens/mobile_welcome_screen.dart';
import 'ui/screens/spotlight_screen.dart';
import 'ui/theme/app_theme.dart';
import 'ui/viewmodels/spotlight_viewmodel.dart';
import 'ui/widgets/tray_menu_window.dart';
import 'utils/auth_callback.dart';
import 'utils/platform_label.dart';
import 'utils/windows_registry.dart';

// Configuration - These values are safe to be public
// Security comes from Supabase Row-Level Security (RLS) policies, not hiding these keys
//
// This is the publishable key from Supabase's current API key scheme, not the
// legacy `anon` JWT it replaced. Both were accepted while legacy keys stayed
// enabled, which is exactly what made the switchover easy to miss: the project
// had already been migrated, and the only thing that broke was a server-side
// comparison against SUPABASE_SERVICE_ROLE_KEY, silently, for a day.
// Moved now because there are no released builds to strand - the key is
// compiled in, so changing it later would mean every old install keeps sending
// the legacy key and legacy keys could never be turned off.
const _supabaseUrl = 'https://xhbggxftvnlkotvehwmj.supabase.co';
const _supabasePublishableKey =
    'sb_publishable_tTHKyNA1zqQDYC8O_kMvvg_HSaoUYje';

/// Top-level background message handler for Firebase Cloud Messaging.
/// This handles notifications when the app is terminated or in background.
@pragma('vm:entry-point')
Future<void> _firebaseBackgroundHandler(RemoteMessage message) async {
  debugPrint('[FCM Background] Received message: ${message.messageId}');

  // Pre-stage the clip so tapping the notification is instant.
  //
  // This isolate runs about a second after the push lands, with the app closed,
  // which is well before the user can reach the notification. CopyActivity is
  // then a pure local read: no network, no Flutter engine, no visible app - it
  // writes the clipboard and finishes. Without this it has nothing to copy, so
  // it falls back to cold starting MainActivity (~2.5s, and the app stays open).
  //
  // The push itself still carries no clipboard value; the content is fetched
  // here over an authenticated, RLS-scoped connection and decrypted in Dart.
  await _prefetchClipForInstantCopy(message);
}

/// Fetch the clip a push refers to and stage it for CopyActivity.
///
/// Best effort by design: every failure path just leaves no cache file, and
/// CopyActivity falls back to opening the app. Never throws - an exception
/// escaping a background isolate kills delivery handling for later messages.
Future<void> _prefetchClipForInstantCopy(RemoteMessage message) async {
  final clipboardId = message.data['clipboard_id'] as String?;
  if (clipboardId == null || clipboardId.isEmpty) return;

  try {
    WidgetsFlutterBinding.ensureInitialized();

    // Before anything that can fail: note that a push really did name this
    // clip. MainActivity is exported, so a notification tap and a third-party
    // app inventing an id look identical in the extras - this record is what
    // tells them apart. Deliberately ahead of the Supabase work below, which
    // has several early returns that would otherwise leave a genuine tap
    // unverifiable.
    await _recordIncomingPush(clipboardId);

    // A background isolate starts with none of main()'s state, so Supabase has
    // to be stood up here. The session is restored from the same persisted
    // store the UI isolate uses, so this runs as the signed-in user and RLS
    // still applies.
    await Supabase.initialize(
      url: _supabaseUrl,
      publishableKey: _supabasePublishableKey,
      // Same guard as the UI isolate: this one also starts a deep-link
      // observer, and it must not accept a session from a URL either.
      authOptions: const FlutterAuthClientOptions(
        detectSessionInUriPredicate: isTrustedAuthCallback,
      ),
    );

    if (Supabase.instance.client.auth.currentUser == null) {
      debugPrint('[FCM Background] No session in this isolate - skipping');
      return;
    }

    // getById() applies RLS and decrypts, so `content` is plaintext here.
    final match = await ClipboardRepository().getById(clipboardId);

    if (match == null) {
      debugPrint('[FCM Background] Clip $clipboardId not in history');
      return;
    }

    // Images and files need a download and a share sheet, neither of which
    // CopyActivity can do. Leave no cache so it routes to the app instead.
    if (match.isImage || match.isFile) {
      debugPrint(
        '[FCM Background] $clipboardId is a file - app will handle it',
      );
      return;
    }

    await _writePendingCopy(match);
  } on Object catch (e) {
    // Object, not Exception. The doc above promises this never throws, but a
    // bad cast raises TypeError - an Error - which an Exception-only handler
    // lets escape, and an exception escaping a background isolate stops later
    // messages from being handled at all.
    debugPrint('[FCM Background] Prefetch failed (tap will open app): $e');
  }
}

/// Note that a push arrived naming [clipboardId], for PushRegistry to check.
///
/// The Kotlin side (PushRegistry.kt) records the same file for foreground
/// deliveries; this covers background and terminated ones. Which of the two
/// runs depends on app state, so both write it and the store is keyed by id.
///
/// Best effort: a failure here costs one silent notification tap, which beats
/// copying a clip whose id nothing vouched for.
Future<void> _recordIncomingPush(String clipboardId) async {
  // Keep in step with PushRegistry.kt.
  const ttl = Duration(hours: 24);
  const maxEntries = 50;

  try {
    final dir = await getApplicationSupportDirectory();
    final file = File('${dir.path}/pending_push.json');

    final entries = <String, int>{};
    if (file.existsSync()) {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is Map) {
        decoded.forEach((key, value) {
          if (key is String && value is int) entries[key] = value;
        });
      }
    }

    final now = DateTime.now().millisecondsSinceEpoch;
    entries[clipboardId] = now;

    final cutoff = now - ttl.inMilliseconds;
    entries.removeWhere((_, at) => at < cutoff);

    if (entries.length > maxEntries) {
      final newest = entries.entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value));
      entries
        ..clear()
        ..addEntries(newest.take(maxEntries));
    }

    await file.writeAsString(jsonEncode(entries), flush: true);
    debugPrint('[FCM Background] Recorded push for $clipboardId');
  } on Object catch (e) {
    debugPrint('[FCM Background] Could not record push: $e');
  }
}

/// Stage one clip's plaintext where CopyActivity can read it synchronously.
///
/// Deliberately holds a single clip and is deleted by CopyActivity the moment
/// it is read, so plaintext is at rest only between the push arriving and the
/// user acting on it. Lives in the app-private files dir (filesDir), which is
/// the same place the widget already keeps its rows.
Future<void> _writePendingCopy(ClipboardItem item) async {
  final dir = await getApplicationSupportDirectory();
  final file = File('${dir.path}/pending_copy.json');

  await file.writeAsString(
    jsonEncode({
      'id': item.id,
      'content': item.content,
      'contentType': item.contentType.value,
      'richTextFormat': item.richTextFormat?.value,
    }),
    flush: true,
  );

  debugPrint('[FCM Background] ✅ Staged clip ${item.id} for instant copy');
}

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();

  // Flutter's image cache defaults to 100MB / 1000 images, which is sized for
  // an app that scrolls through photos. This one shows small history
  // thumbnails and at most one preview, so the default is a ceiling it would
  // never need but could still reach - decoded clipboard images are large.
  PaintingBinding.instance.imageCache
    ..maximumSizeBytes = 24 << 20
    ..maximumSize = 100;

  // debugPrint is NOT stripped from release builds - it formats its argument
  // and pushes it through a throttling queue. This app is always resident and
  // logs on the 5-second clipboard tick and once per history item, so in
  // release that is a steady drip of string building and timer work for output
  // nobody can read. Silence it there; debug and profile builds are untouched.
  if (kReleaseMode) {
    debugPrint = (message, {wrapWidth}) {};
  }

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

  // Only one desktop instance may run. Without this, the ghostcopy:// registry
  // entry starts a whole second app every time Google OAuth redirects back -
  // second window, second tray icon, second hotkey - and the callback lands in
  // that new process, so the running app never signs in and the browser sits
  // on the callback page forever.
  //
  // --send-file is exempt: it is a headless one-shot that uploads and exits
  // without any UI, so a second process there is harmless and simpler.
  if (_isDesktop() && !args.contains('--send-file')) {
    final isPrimary = await SingleInstance.instance.acquire(args);
    if (!isPrimary) {
      // Arguments were handed to the running instance; nothing else to do.
      exit(0);
    }
  }

  // Check if app was launched at startup (for hidden mode)
  final launchedAtStartup = args.contains('--launched-at-startup');

  // Start periodic cleanup timer (every 15 minutes)
  TempFileService.instance.startPeriodicCleanup();

  // Sweep last session's temp files, but do not hold startup for it.
  //
  // This walks the temp directory, and on a cold start that disk work measured
  // ~340ms - longer than Supabase.initialize() beside it, so it, not Supabase,
  // was setting the length of the await below. Nothing on the startup path
  // depends on the sweep: it is housekeeping for files already orphaned by a
  // previous run, and a few more seconds on disk costs nothing.
  unawaited(
    TempFileService.instance.cleanupTempFiles().catchError((Object e) {
      debugPrint('[Main] ⚠️ Temp file cleanup failed: $e');
    }),
  );

  // PARALLEL GROUP 1: Independent startup operations
  await Future.wait([
    // Initialize Supabase with session persistence
    Supabase.initialize(
      url: _supabaseUrl,
      publishableKey: _supabasePublishableKey,
      // supabase_flutter starts its own AppLinks deep-link observer that calls
      // getSessionFromUrl directly, bypassing _handleDeepLinkArgs. Its default
      // predicate accepts any URI carrying access_token, so without this the
      // session-injection hole stays open on that route.
      authOptions: const FlutterAuthClientOptions(
        detectSessionInUriPredicate: isTrustedAuthCallback,
      ),
    ),

    // Register custom URL scheme for OAuth callbacks (Windows only)
    if (Platform.isWindows) _registerWindowsUrlScheme(),
    if (Platform.isWindows) _registerWindowsContextMenu(),
  ]);

  // Initialize services that depend on Supabase
  final deviceService = DeviceService();
  final authService = AuthService(deviceService: deviceService);

  locator
    ..registerSingleton<IAuthService>(authService)
    ..registerSingleton<IDeviceService>(deviceService);

  // Launched from the Explorer context menu ("Send with GhostCopy"). Send the
  // file and exit WITHOUT building a window, tray icon or hotkey - otherwise
  // every right-click would leave a second instance and a duplicate tray icon
  // behind. This runs before any UI is created for that reason.
  final sendFileIndex = args.indexOf('--send-file');
  if (sendFileIndex != -1 && sendFileIndex + 1 < args.length) {
    final result = await _sendFileFromCommandLine(
      args[sendFileIndex + 1],
      authService,
    );
    exit(result);
  }

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

    // Complete OAuth when the browser hands us back a ghostcopy:// callback -
    // either in this launch's arguments (app was closed) or forwarded from a
    // later launch by SingleInstance (app was already running). Without this
    // nothing ever consumed the callback, so signing in with Google appeared
    // to do nothing and left the browser tab open.
    unawaited(_handleDeepLinkArgs(args));
    // SingleInstance.listen, not .incomingArguments.listen: the server starts
    // accepting connections inside acquire() near the top of main, but this
    // runs only after Supabase and the rest of desktop setup. A broadcast
    // stream has no replay, so a callback forwarded in that window would be
    // dropped. listen() flushes that backlog.
    SingleInstance.instance.listen((forwarded) {
      unawaited(_handleDeepLinkArgs(forwarded.split(' ')));
      // A second launch without a URL is the user asking for the app, so show
      // the window rather than silently doing nothing.
      if (!forwarded.contains('ghostcopy://')) {
        unawaited(locator<IWindowService>().showSpotlight());
      }
    });

    runApp(MyApp(launchedAtStartup: launchedAtStartup));
  } else {
    // Mobile app - initialize Firebase and FCM (optional)
    FcmService? fcmService;
    // Deliberately a Future, not an awaited String. See where it is assigned.
    Future<String?>? fcmTokenFuture;
    // ignore: cancel_subscriptions - Subscriptions are cancelled in MyApp.dispose()
    StreamSubscription<String>? tokenRefreshSubscription;
    // ignore: cancel_subscriptions - Subscriptions are cancelled in MyApp.dispose()
    StreamSubscription<RemoteMessage>? foregroundMessageSubscription;
    // ignore: cancel_subscriptions - Subscriptions are cancelled in MyApp.dispose()
    StreamSubscription<RemoteMessage>? messageOpenedAppSubscription;

    // Both before anything registers this device or sends a clip, and both
    // independent of each other - so started together rather than one after the
    // other, as the desktop branch above already does. The device name is read
    // synchronously from here on and resolving a phone's model is a
    // platform-channel round trip, so it has to be settled before the first
    // send: `devices` is uniquely indexed on
    // (user_id, device_type, device_name).
    final settingsService = SettingsService();
    await Future.wait([
      ClipboardRepository.initializeDeviceName(),
      settingsService.initialize(),
    ]);
    debugPrint('[App] ✅ Settings service initialized for mobile');
    locator
      ..registerSingleton<ISettingsService>(settingsService)
      // Core mobile services required by screens/viewmodels even when
      // Firebase/FCM is not configured.
      ..registerSingleton<IClipboardRepository>(ClipboardRepository.instance)
      ..registerSingleton<ISecurityService>(SecurityService())
      ..registerSingleton<ITransformerService>(TransformerService());

    try {
      await Firebase.initializeApp();
      debugPrint('[App] ✅ Firebase initialized for mobile');

      // Register background message handler (must be before other FCM setup)
      FirebaseMessaging.onBackgroundMessage(_firebaseBackgroundHandler);
      debugPrint('[App] ✅ Firebase background message handler registered');

      // Initialize FCM service for push notifications
      fcmService = FcmService();
      await fcmService.initialize();

      locator.registerSingleton<IFcmService>(fcmService);

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

      // Start fetching the FCM token, but do NOT wait for it here.
      //
      // getToken() is a network round trip to Google's registration servers -
      // routinely 1-3s on a cold start, and unbounded on a bad connection. It
      // used to be awaited before runApp(), so every launch held on a blank
      // screen for it even though nothing in the first frame needs a push token:
      // both consumers (device registration, and the welcome screen's
      // post-sign-in callback) run well after the UI is on screen and simply
      // await this future when they get there.
      fcmTokenFuture = fcmService.getToken().then((token) {
        debugPrint(
          token != null
              ? '[App] FCM token ready'
              : '[App] ⚠️ No FCM token - push will not arrive',
        );
        return token;
      });

      // Nothing awaits this future until after startup, so an early failure
      // would otherwise surface as an unhandled async error and take down the
      // zone. Push is optional; startup is not.
      unawaited(
        fcmTokenFuture.catchError((Object e) {
          debugPrint('[App] ⚠️ FCM token fetch failed: $e');
          return null;
        }),
      );

      // Listen for token refresh and update device (store subscription for cleanup)
      tokenRefreshSubscription = fcmService.tokenRefreshStream.listen((
        newToken,
      ) async {
        debugPrint('[App] 🔄 FCM token refreshed, updating device...');
        // updateFcmToken() silently returns when the device has not been
        // registered yet, and a refresh can land before startup registration
        // finishes - dropping the new token and leaving a dead one on the row.
        // registerCurrentDevice() upserts and now carries the token, so this
        // is safe in one write.
        try {
          await deviceService.registerCurrentDevice(fcmToken: newToken);
        } on Exception catch (e) {
          debugPrint('[App] ⚠️ Could not store refreshed FCM token: $e');
        }
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

    // Draw behind the status and navigation bars.
    //
    // The strip beside a punch-hole or notch holds only the clock, signal and
    // battery - the OS draws those over whatever is underneath. Leaving it as
    // an opaque bar wasted a band of screen on every modern phone. The AppBar
    // now extends up into it (Material adds MediaQuery.padding.top to its own
    // height automatically), so the header's surface colour runs to the very
    // top and its content still begins below the cutout.
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setSystemUIOverlayStyle(
      const SystemUiOverlayStyle(
        // Transparent, not coloured: the AppBar behind it supplies the colour.
        statusBarColor: Colors.transparent,
        // Light glyphs, because everything behind them is the dark theme.
        statusBarIconBrightness: Brightness.light,
        statusBarBrightness: Brightness.dark, // iOS reads this one
        systemNavigationBarColor: Colors.transparent,
        systemNavigationBarIconBrightness: Brightness.light,
        systemNavigationBarContrastEnforced: false,
      ),
    );

    runApp(
      MyApp(
        fcmTokenFuture: fcmTokenFuture,
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
    this.fcmTokenFuture,
    this.tokenRefreshSubscription,
    this.foregroundMessageSubscription,
    this.messageOpenedAppSubscription,
    this.launchedAtStartup = false,
    super.key,
  });

  final Future<String?>? fcmTokenFuture;
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
  StreamSubscription<bool>? _gameModeMenuSub;

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

      // macOS uses a real NSMenu, which has to be rebuilt whenever Game Mode
      // changes so its checkmark matches the current state. On Windows this
      // is a no-op and the custom window is used instead.
      if (Platform.isMacOS) {
        unawaited(_refreshNativeTrayMenu());
        _gameModeMenuSub = locator<IGameModeService>().isActiveStream.listen(
          (_) => unawaited(_refreshNativeTrayMenu()),
        );
        unawaited(_listenForSharedFiles(locator<IAuthService>()));
      }

      // Register the global hotkey the user chose, falling back to the default
      // only when nothing has been saved. This used to always register the
      // hardcoded default, so a customised shortcut was discarded on restart.
      _onHotkeyPressed = _handleHotkeySpotlight;
      unawaited(_registerSavedHotkey());
    } else {
      // Mobile: Check if user is already signed in
      final currentUser = locator<IAuthService>().currentUser;
      if (currentUser != null && !currentUser.isAnonymous) {
        // User is already authenticated, skip welcome screen
        _mobileAuthComplete = true;
        debugPrint('[Mobile] User already signed in, skipping welcome screen');

        // Persist the FCM token on THIS path too. It was only ever written
        // inside MobileWelcomeScreen's onAuthComplete callback, which never
        // runs for an already-signed-in user - the welcome screen is skipped
        // entirely. So the token was fetched on every launch and thrown away,
        // and the devices row kept whatever token happened to be current at
        // first sign-in. FCM rotates tokens (reinstall, cleared data, restore
        // to a new device), and every rotation silently killed push until the
        // user signed out and back in.
        unawaited(_registerDeviceForPush());
      }
    }
  }

  /// Register this device and store its current FCM token.
  ///
  /// Safe to run on every launch: registerCurrentDevice() upserts, and
  /// updateFcmToken() is a no-op write when the value has not changed.
  Future<void> _registerDeviceForPush() async {
    // Awaited here rather than at startup: by the time this runs the UI is
    // already on screen, so waiting on Google's registration servers costs the
    // user nothing.
    final token = await widget.fcmTokenFuture;
    try {
      await locator<IDeviceService>().registerCurrentDevice();
      if (token != null) {
        await locator<IDeviceService>().updateFcmToken(token);
        debugPrint('[Mobile] ✅ FCM token stored for signed-in device');
      } else {
        debugPrint('[Mobile] ⚠️ No FCM token available - push will not arrive');
      }
    } on Exception catch (e) {
      // Push is not worth failing startup over; sync still works without it.
      debugPrint('[Mobile] ⚠️ Could not register device for push: $e');
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
      _gameModeMenuSub?.cancel();
      _gameModeMenuSub = null;

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
      if (locator.isRegistered<IFcmService>()) {
        locator<IFcmService>().dispose();
      }
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

  Future<void> _refreshNativeTrayMenu() async {
    final gameMode = locator<IGameModeService>();
    await locator<ITrayService>().setContextMenu([
      TrayMenuItem(
        label: 'Show Spotlight',
        onTap: () => locator<IWindowService>().showSpotlight(),
      ),
      TrayMenuItem(
        label: 'Game Mode',
        isChecked: gameMode.isActive,
        onTap: gameMode.toggle,
      ),
      TrayMenuItem(label: 'Settings', onTap: _openSettingsFromTray),
      const TrayMenuItem.separator(),
      TrayMenuItem(label: 'Quit GhostCopy', onTap: _handleQuit),
    ]);
  }

  /// Windows only. macOS pops a real NSMenu from TrayService and never
  /// reaches this, so there are no platform branches below - one that looked
  /// like the place to fix macOS placement was exactly the trap this note
  /// replaces.
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

    // Wait for resize to complete
    await Future<void>.delayed(const Duration(milliseconds: 50));

    // Bottom-right, because the taskbar is at the bottom.
    //
    // No macOS branch: macOS pops a real NSMenu from TrayService instead and
    // never reaches this window, so a branch here could only ever be dead
    // code that looked like the place to fix macOS placement.
    await windowManager.setAlignment(Alignment.bottomRight);

    // Show with correct size and content
    await windowManager.show();
    await windowManager.focus();
  }

  void _hideTrayMenu() {
    setState(() => _showingTrayMenu = false);
    locator<IWindowService>().hideSpotlight();
    // No "App closed to tray" toast: hiding to the tray is the app's normal
    // resting state, so announcing it every time is noise. It was also a
    // fire-and-forget Future.delayed that could fire after disposal.
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
      // No overscroll stretch or glow anywhere in the app.
      scrollBehavior: Adaptive.scrollBehavior,
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
                // Guarded: the child now calls back even when the panel was
                // already open, so without this a repeat tray click rebuilt
                // this whole subtree to write false over false.
                if (_openSettingsOnShow) {
                  setState(() => _openSettingsOnShow = false);
                }
              },
            );
    }

    // Mobile app - show welcome screen or main screen based on auth state
    if (!_mobileAuthComplete) {
      return MobileWelcomeScreen(
        fcmTokenFuture: widget.fcmTokenFuture,
        onAuthComplete: () async {
          // Register device with FCM token after auth
          await locator<IDeviceService>().registerCurrentDevice();

          // Update FCM token if available. Resolved by now in practice - the
          // fetch starts at launch and signing in takes seconds - but awaited
          // rather than assumed.
          final token = await widget.fcmTokenFuture;
          if (token != null) {
            await locator<IDeviceService>().updateFcmToken(token);
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

/// The shortcut used when the user has never chosen one.
///
/// A global hotkey takes its combination away from every app, so the default
/// has to be one almost nothing else binds. Ctrl+Shift+S is safe on Windows.
///
/// On macOS it is Option+Space, and the two obvious alternatives are worse:
///
///   - Cmd+Shift+S is Save As in most apps, and Cmd+Shift+V is
///     paste-without-formatting in browsers, editors and chat apps. Taking
///     either globally breaks a command people use constantly.
///   - Ctrl+Shift+Space types no character and collides with nothing, but
///     nobody reaches for it, which for a shortcut meant to be pressed dozens
///     of times a day is its own kind of wrong.
///
/// Option+Space is a deliberate, known tradeoff rather than an oversight:
/// macOS types a non-breaking space with it, so while GhostCopy is resident
/// that character cannot be entered. This is accepted because the key is a
/// launcher convention on this platform - Raycast and Alfred both ship
/// Option+Space as their default - and because a non-breaking space is a
/// character most users never type on purpose. Anyone who does need it, or
/// who already runs a launcher on this combination, can rebind in Settings;
/// only this fallback is affected.
final HotKey defaultHotkey = Platform.isMacOS
    ? const HotKey(key: 'space', alt: true)
    : const HotKey(key: 's', ctrl: true, shift: true);

/// Invoked when the global hotkey fires.
///
/// Set by [_MyAppState], which owns the tray/window state the handler needs.
/// Held at top level so [applyHotkey] can re-register from anywhere (the
/// settings panel) without threading the callback through the widget tree.
Future<void> Function()? _onHotkeyPressed;

void _invokeHotkeyCallback() {
  unawaited(_onHotkeyPressed?.call());
}

/// Register [hotkey] as the global shortcut and persist it.
///
/// Single entry point so the Spotlight callback is wired in exactly one place.
/// Throws [UnsupportedHotkeyException] if the key cannot be registered; the
/// previous registration is left in place in that case, and nothing is saved.
Future<void> applyHotkey(HotKey hotkey) async {
  final hotkeyService = locator<IHotkeyService>();

  // Register first: if the new combo is rejected, the old one must survive and
  // nothing should be written to settings.
  await hotkeyService.registerHotkey(hotkey, _invokeHotkeyCallback);

  if (hotkey != _activeHotkey) {
    await hotkeyService.unregisterHotkey(_activeHotkey);
  }
  _activeHotkey = hotkey;

  await locator<ISettingsService>().setHotkey(hotkey);
  debugPrint('[Hotkey] Applied ${hotkey.toStorageString()}');
}

/// The shortcut currently registered with the OS.
HotKey _activeHotkey = defaultHotkey;

/// Register the saved global hotkey, falling back to [defaultHotkey].
///
/// A saved hotkey naming a key this platform cannot register (written by an
/// older build, which allowed keys the service could not map) falls back rather
/// than leaving the app with no shortcut at all.
Future<void> _registerSavedHotkey() async {
  final hotkeyService = locator<IHotkeyService>();
  HotKey? saved;

  try {
    saved = await locator<ISettingsService>().getHotkey();
  } on Object catch (e) {
    debugPrint('[Hotkey] Could not read saved hotkey: $e');
  }

  final wanted = saved ?? defaultHotkey;

  try {
    await hotkeyService.registerHotkey(wanted, _invokeHotkeyCallback);
    _activeHotkey = wanted;
    debugPrint('[Hotkey] Registered ${wanted.toStorageString()}');
    return;
  } on UnsupportedHotkeyException catch (e) {
    debugPrint('[Hotkey] $e - falling back to default');
  } on Object catch (e) {
    debugPrint('[Hotkey] Failed to register ${wanted.toStorageString()}: $e');
  }

  if (wanted == defaultHotkey) return;

  try {
    await hotkeyService.registerHotkey(defaultHotkey, _invokeHotkeyCallback);
    _activeHotkey = defaultHotkey;
    debugPrint(
      '[Hotkey] Registered default ${defaultHotkey.toStorageString()}',
    );
  } on Object catch (e) {
    debugPrint('[Hotkey] Failed to register default hotkey: $e');
  }
}

/// Feed a ghostcopy:// callback URL to Supabase so the session is established.
///
/// Handles both `ghostcopy://auth-callback` (Google OAuth) and
/// `ghostcopy://reset-password`.
///
/// The URL is untrusted: Windows registers `ghostcopy://` as `"<exe>" "%1"`
/// (see [_registerWindowsUrlScheme]), so any web page or local process can put
/// one in front of this function, and a second launch forwards it here through
/// SingleInstance. It is therefore validated rather than handed straight to
/// `getSessionFromUrl`, which would persist whatever session the URL described.
Future<void> _handleDeepLinkArgs(List<String> args) async {
  final link = args.firstWhere(
    (a) => a.startsWith('ghostcopy://'),
    orElse: () => '',
  );
  if (link.isEmpty) return;

  debugPrint('[Main] 🔗 Handling deep link');

  final decision = AuthCallbackDecision.evaluate(link);
  if (!decision.isAccepted) {
    debugPrint(
      '[Main] ⛔ Refused deep link (${decision.rejection!.name}): '
      '${decision.detail ?? "no detail"}',
    );
    return;
  }

  try {
    final auth = Supabase.instance.client.auth;

    if (decision.code != null) {
      // exchangeCodeForSession, not getSessionFromUrl: it requires the PKCE
      // code verifier this process stored when it started the flow, so a code
      // the app did not ask for cannot be redeemed.
      await auth.exchangeCodeForSession(decision.code!);
    } else {
      // Email confirmation links carry a one-time token instead of a code,
      // because a code can only be redeemed on the device that began the flow -
      // and mail is routinely opened somewhere else. gotrue checks the token
      // server-side, so possession of the account's mailbox is what is proved.
      await auth.verifyOTP(
        tokenHash: decision.tokenHash,
        type: decision.otpType!,
      );
    }
    debugPrint('[Main] ✅ Session established from deep link');

    // Bring the app forward so the user sees that sign-in worked - they are
    // currently looking at a browser window.
    if (locator.isRegistered<IWindowService>()) {
      await locator<IWindowService>().showSpotlight();
    }
  } on Object catch (e) {
    debugPrint('[Main] ⚠️ Failed to handle deep link: $e');
  }
}

/// Upload a file passed on the command line, then return so main() can exit.
///
/// Uploads the file at [path] to the user's other devices.
///
/// Shared by the Windows Explorer context menu and the macOS Services entry,
/// so both send exactly the same way. [initializeAuth] is for the Windows
/// path, which runs before the app has initialised anything.
Future<({bool ok, String message})> _sendSharedFile(
  String path,
  IAuthService authService, {
  bool initializeAuth = false,
}) async {
  try {
    // Directories are rejected by name rather than falling through to the
    // existsSync check below, which is false for a directory and would report
    // a folder that is plainly there as missing. The macOS service is declared
    // for public.data so Finder should not offer it on folders at all, but the
    // Windows path shares this function and a bundle is a directory too.
    if (FileSystemEntity.isDirectorySync(path)) {
      return (
        ok: false,
        message: 'Folders cannot be sent. Select a file instead.',
      );
    }
    final file = File(path);
    if (!file.existsSync()) {
      return (ok: false, message: 'The selected file no longer exists.');
    }
    // Check the size before allocating a potentially multi-GB file in RAM.
    if (await file.length() > ClipboardLimits.maxFileBytes) {
      return (
        ok: false,
        message:
            'This file is too large. GhostCopy supports files up to '
            '${ClipboardLimits.maxFileLabel}.',
      );
    }
    if (authService.currentUserId == null) {
      return (
        ok: false,
        message: 'Open GhostCopy and sign in before sending a file.',
      );
    }

    if (initializeAuth) await authService.initialize();

    // Honour the "Send to devices" setting, so a context-menu send goes to the
    // same devices as every other send instead of always going to all of them.
    // The Windows path runs before the locator is populated, hence the fallback.
    final ISettingsService settings;
    if (locator.isRegistered<ISettingsService>()) {
      settings = locator<ISettingsService>();
    } else {
      settings = SettingsService();
      await settings.initialize();
    }
    final targets = await settings.getAutoSendTargetDevices();

    final bytes = await file.readAsBytes();
    final filename = file.uri.pathSegments.last;
    final typeInfo = FileTypeService.instance.detectFromBytes(bytes, filename);
    await ClipboardRepository.instance.insertFile(
      userId: authService.currentUserId!,
      deviceType: ClipboardRepository.getCurrentDeviceType(),
      deviceName: ClipboardRepository.getCurrentDeviceName(),
      fileBytes: bytes,
      mimeType: typeInfo.mimeType,
      contentType: typeInfo.contentType,
      originalFilename: filename,
      // null, not an empty list: the repository reads null as "every device".
      targetDeviceTypes: targets.isEmpty ? null : targets.toList(),
    );

    final where = targets.isEmpty
        ? 'your other devices'
        : targets.map(platformLabel).join(', ');
    return (ok: true, message: 'Sent $filename to $where.');
  } on Exception catch (e) {
    debugPrint('[SendFile] Failed to send file: $e');
    return (
      ok: false,
      message:
          'The file could not be sent. Check your connection and try '
          'again.',
    );
  }
}

/// Used by the Windows Explorer context menu. Deliberately minimal: no window,
/// no tray, no hotkey - just auth, upload, done.
Future<int> _sendFileFromCommandLine(
  String path,
  IAuthService authService,
) async {
  final result = await _sendSharedFile(path, authService, initializeAuth: true);
  final exitCode = result.ok ? 0 : 1;
  final message = result.message;
  debugPrint('[SendFile] $message');
  if (Platform.isWindows) {
    // Native feedback works without rendering the main Flutter window, a tray
    // icon, or a second persistent app instance. It also survives Focus Assist.
    await const MethodChannel(
      'com.ghostcopy/send_file',
    ).invokeMethod<void>('showResult', message);
  }
  return exitCode;
}

/// Receives files shared into GhostCopy from Finder's Share menu.
///
/// Delivered by the macOS Service, which runs inside this process and hands
/// over the file paths. Sending matches the Windows context menu: straight to
/// the default devices, with a notification rather than a staged file waiting
/// to be sent.
Future<void> _listenForSharedFiles(IAuthService authService) async {
  const channel = MethodChannel('com.ghostcopy.app/share');

  Future<void> sendAll(List<String> paths) async {
    for (final path in paths) {
      final result = await _sendSharedFile(path, authService);
      locator<INotificationService>().showToast(
        message: result.message,
        type: result.ok ? NotificationType.success : NotificationType.error,
      );
    }
  }

  channel.setMethodCallHandler((call) async {
    if (call.method == 'sendFiles') {
      await sendAll(List<String>.from(call.arguments as List));
    }
  });

  // Draining on startup covers the case where macOS launched the app purely to
  // deliver the file, so the service fired before Dart was listening.
  try {
    final pending = await channel.invokeListMethod<String>('ready');
    if (pending != null && pending.isNotEmpty) await sendAll(pending);
  } on PlatformException catch (e) {
    debugPrint('[Share] Could not drain pending shared files: $e');
  }
}

/// Add "Send with GhostCopy" to the Explorer right-click menu for all files.
///
/// Written under HKCU so no elevation is needed. `*` covers every file type.
/// The command passes the clicked path as --send-file, which main() handles
/// before any UI exists.
Future<void> _registerWindowsContextMenu() async {
  try {
    final exePath = Platform.resolvedExecutable;
    const key = r'HKCU\Software\Classes\*\shell\GhostCopySend';

    await runWindowsRegistryCommand([
      'add',
      key,
      '/ve',
      '/d',
      'Send with GhostCopy',
      '/f',
    ]);
    await runWindowsRegistryCommand([
      'add',
      key,
      '/v',
      'Icon',
      '/d',
      '"$exePath",0',
      '/f',
    ]);
    // Interpolated, NOT a raw string: r'$key' is the literal text "$key",
    // so the adjacent literals used to concatenate to `$key\command` and
    // reg rejected it as a key name with no hive. The menu entry was
    // created with its label and icon but no command subkey, so clicking
    // "Send with GhostCopy" did nothing.
    await runWindowsRegistryCommand([
      'add',
      '$key\\command',
      '/ve',
      '/d',
      '"$exePath" --send-file "%1"',
      '/f',
    ]);

    debugPrint('[Main] ✅ Registered "Send with GhostCopy" context menu');
  } on Exception catch (e) {
    debugPrint('[Main] ⚠️ Failed to register context menu: $e');
    // Non-fatal - continue app startup
  }
}

/// Register ghostcopy:// URL scheme in Windows Registry for OAuth callbacks
Future<void> _registerWindowsUrlScheme() async {
  try {
    // Get the executable path
    final exePath = Platform.resolvedExecutable;

    // Register the URL protocol in Windows Registry
    // This allows ghostcopy:// links to open the app
    await runWindowsRegistryCommand([
      'add',
      r'HKCU\Software\Classes\ghostcopy',
      '/ve',
      '/d',
      'URL:GhostCopy Protocol',
      '/f',
    ]);

    await runWindowsRegistryCommand([
      'add',
      r'HKCU\Software\Classes\ghostcopy',
      '/v',
      'URL Protocol',
      '/d',
      '',
      '/f',
    ]);

    await runWindowsRegistryCommand([
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
