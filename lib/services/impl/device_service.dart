import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../repositories/clipboard_repository.dart';
import '../../utils/platform_label.dart';
import '../device_service.dart';

/// Concrete implementation of IDeviceService
///
/// Manages device registration and tracking in Supabase.
/// Desktop devices register without FCM tokens.
/// Mobile devices will add FCM tokens when implemented.
class DeviceService implements IDeviceService {
  /// Constructor with optional Supabase client for testing
  DeviceService({SupabaseClient? supabaseClient})
    : _supabase = supabaseClient ?? Supabase.instance.client;

  final SupabaseClient _supabase;
  bool _initialized = false;
  String? _currentDeviceId;

  // Device list caching to reduce API calls
  List<Device>? _cachedDevices;
  DateTime? _lastDeviceFetch;
  static const Duration _cacheExpiry = Duration(minutes: 5);

  // Rate limiting for updateLastActive
  DateTime? _lastActiveUpdateTime;
  static const Duration _minActiveUpdateInterval = Duration(minutes: 5);

  @override
  Future<void> initialize() async {
    if (_initialized) {
      debugPrint('[DeviceService] Already initialized, skipping');
      return;
    }

    try {
      debugPrint('[DeviceService] Starting initialization...');
      _initialized = true;
      debugPrint(
        '[DeviceService] ✅ Initialized successfully (caching enabled: 5min TTL)',
      );
    } on Exception catch (e) {
      debugPrint('[DeviceService] ❌ Failed to initialize: $e');
      rethrow;
    }
  }

  void _ensureInitialized() {
    if (!_initialized) {
      throw StateError(
        'DeviceService not initialized. Call initialize() first.',
      );
    }
  }

  void _ensureAuthenticated() {
    if (_supabase.auth.currentUser == null) {
      throw StateError('User not authenticated. Cannot register device.');
    }
  }

  /// Drop the row this device registered under before it had a real name.
  ///
  /// Mobile used to register as the bare platform - "iOS Device" - because
  /// getCurrentDeviceName() returned nothing there. It resolves a model name
  /// now, and the conflict key is (user_id, device_type, device_name), so the
  /// first launch after an upgrade inserts a SECOND row rather than renaming
  /// the first.
  ///
  /// Both rows then hold the same FCM token, and send-clipboard-notification
  /// sends once per matching row without de-duplicating tokens - so every clip
  /// from another platform arrived as two notifications, and Settings listed a
  /// device that no longer exists.
  ///
  /// Scoped to the placeholder name exactly, and skipped when that is still
  /// what this device is called, so it can never delete a real device: a
  /// second phone of the same platform has a model name of its own.
  ///
  /// Best effort. A failure here leaves a duplicate notification, which is
  /// worth a log and not worth failing a registration for.
  Future<void> _removeLegacyGenericRow({
    required String userId,
    required String deviceType,
    required String currentName,
    required String? fcmToken,
  }) async {
    final legacyName = '${platformLabel(deviceType)} Device';
    // A generic row may belong to another phone that has not upgraded yet.
    // The FCM token is the only server-side proof that it was this install's
    // row, so never delete a row without matching the current token.
    if (currentName == legacyName || fcmToken == null || fcmToken.isEmpty) {
      return;
    }

    try {
      await _supabase
          .from('devices')
          .delete()
          .eq('user_id', userId)
          .eq('device_type', deviceType)
          .eq('device_name', legacyName)
          .eq('fcm_token', fcmToken);
      debugPrint('[DeviceService] Removed legacy "$legacyName" row');
    } on Object catch (e) {
      debugPrint('[DeviceService] Could not remove the legacy row: $e');
    }
  }

  @override
  Future<bool> registerCurrentDevice({String? fcmToken}) async {
    _ensureInitialized();
    _ensureAuthenticated();

    try {
      final userId = _supabase.auth.currentUser!.id;
      final deviceType = ClipboardRepository.getCurrentDeviceType();
      final deviceName =
          ClipboardRepository.getCurrentDeviceName() ??
          '${platformLabel(deviceType)} Device';

      debugPrint(
        '[DeviceService] Registering device: $deviceType ($deviceName)',
      );

      // Upsert device (insert or update if exists)
      // Unique constraint on (user_id, device_type, device_name) ensures no duplicates
      final response = await _supabase
          .from('devices')
          .upsert({
            'user_id': userId,
            'device_type': deviceType,
            'device_name': deviceName,
            // Upsert writes every column, so this CLEARS any stored token
            // unless one is supplied. Mobile callers pass their token here so
            // registration is a single write; previously they followed this
            // with updateFcmToken(), which cost a second round-trip and left a
            // window in between where push was broken for the device.
            'fcm_token': fcmToken,
            'last_active': DateTime.now().toUtc().toIso8601String(),
          }, onConflict: 'user_id,device_type,device_name')
          .select('id')
          .single();

      _currentDeviceId = response['id'] as String;

      debugPrint(
        '[DeviceService] ✅ Device registered successfully (ID: $_currentDeviceId)',
      );

      await _removeLegacyGenericRow(
        userId: userId,
        deviceType: deviceType,
        currentName: deviceName,
        fcmToken: fcmToken,
      );

      // Invalidate cache since device list changed
      _invalidateCache();
      return true;
    } on PostgrestException catch (e) {
      debugPrint(
        '[DeviceService] ❌ Postgres error registering device: ${e.message}',
      );
      // Don't rethrow - device registration is non-critical
      return false;
    } on Exception catch (e) {
      debugPrint('[DeviceService] ❌ Failed to register device: $e');
      // Don't rethrow - device registration is non-critical
      return false;
    }
  }

  @override
  Future<List<Device>> getUserDevices({bool forceRefresh = false}) async {
    _ensureInitialized();
    _ensureAuthenticated();

    // Check cache first (unless force refresh requested)
    if (!forceRefresh && _isCacheValid()) {
      // debugPrint('[DeviceService] Returning cached devices (${_cachedDevices!.length} device(s))');
      return _cachedDevices!;
    }

    try {
      final userId = _supabase.auth.currentUser!.id;

      final response = await _supabase
          .from('devices')
          .select()
          .eq('user_id', userId)
          .order('last_active', ascending: false);

      final devices = (response as List)
          .map((json) => Device.fromJson(json as Map<String, dynamic>))
          .toList();

      // Update cache
      _cachedDevices = devices;
      _lastDeviceFetch = DateTime.now();

      debugPrint(
        '[DeviceService] Fetched and cached ${devices.length} device(s)',
      );

      return devices;
    } on PostgrestException catch (e) {
      debugPrint(
        '[DeviceService] ❌ Postgres error fetching devices: ${e.message}',
      );
      return [];
    } on Exception catch (e) {
      debugPrint('[DeviceService] ❌ Failed to fetch devices: $e');
      return [];
    }
  }

  @override
  Future<void> updateFcmToken(String fcmToken) async {
    _ensureInitialized();
    _ensureAuthenticated();

    if (_currentDeviceId == null) {
      debugPrint(
        '[DeviceService] ⚠️ Cannot update FCM token: device not registered',
      );
      return;
    }

    try {
      await _supabase
          .from('devices')
          .update({
            'fcm_token': fcmToken,
            'last_active': DateTime.now().toUtc().toIso8601String(),
          })
          .eq('id', _currentDeviceId!);

      debugPrint('[DeviceService] ✅ FCM token updated');
    } on PostgrestException catch (e) {
      if (e.code == '23505') {
        // devices_fcm_token_global_unique: this registration token is still
        // claimed by a row on another account, usually because the device
        // switched accounts without the old rows being cleaned up. Reclaim it,
        // otherwise push silently never arrives on this device.
        debugPrint(
          '[DeviceService] ⚠️ FCM token already claimed by another account - '
          'reclaiming it for this device',
        );
        try {
          await _supabase
              .from('devices')
              .delete()
              .eq('fcm_token', fcmToken)
              .neq('id', _currentDeviceId!);

          await _supabase
              .from('devices')
              .update({
                'fcm_token': fcmToken,
                'last_active': DateTime.now().toUtc().toIso8601String(),
              })
              .eq('id', _currentDeviceId!);

          debugPrint('[DeviceService] ✅ FCM token reclaimed');
          return;
        } on Exception catch (retryError) {
          // RLS scopes the delete to the caller's own rows, so a row owned by a
          // different account cannot be removed from here and this will fail.
          debugPrint(
            '[DeviceService] ❌ Could not reclaim FCM token - push will not '
            'arrive on this device: $retryError',
          );
          return;
        }
      }
      debugPrint(
        '[DeviceService] ❌ Postgres error updating FCM token: ${e.message}',
      );
    } on Exception catch (e) {
      debugPrint('[DeviceService] ❌ Failed to update FCM token: $e');
    }
  }

  @override
  Future<void> updateLastActive() async {
    _ensureInitialized();
    _ensureAuthenticated();

    if (_currentDeviceId == null) {
      debugPrint(
        '[DeviceService] ⚠️ Cannot update last active: device not registered',
      );
      return;
    }

    // Rate limit: Skip update if called too frequently
    if (_lastActiveUpdateTime != null &&
        DateTime.now().difference(_lastActiveUpdateTime!) <
            _minActiveUpdateInterval) {
      debugPrint(
        '[DeviceService] ⏭️ Skipping last active update (rate limited)',
      );
      return;
    }

    try {
      await _supabase
          .from('devices')
          .update({'last_active': DateTime.now().toUtc().toIso8601String()})
          .eq('id', _currentDeviceId!);

      _lastActiveUpdateTime = DateTime.now();

      debugPrint('[DeviceService] ✅ Last active updated');
    } on PostgrestException catch (e) {
      debugPrint(
        '[DeviceService] ❌ Postgres error updating last active: ${e.message}',
      );
    } on Exception catch (e) {
      debugPrint('[DeviceService] ❌ Failed to update last active: $e');
    }
  }

  @override
  Future<void> unregisterCurrentDevice() async {
    _ensureInitialized();
    _ensureAuthenticated();

    if (_currentDeviceId == null) {
      debugPrint('[DeviceService] ⚠️ No device to unregister');
      return;
    }

    try {
      await _supabase.from('devices').delete().eq('id', _currentDeviceId!);

      debugPrint('[DeviceService] ✅ Device unregistered');
      _currentDeviceId = null;
    } on PostgrestException catch (e) {
      debugPrint(
        '[DeviceService] ❌ Postgres error unregistering device: ${e.message}',
      );
    } on Exception catch (e) {
      debugPrint('[DeviceService] ❌ Failed to unregister device: $e');
    }
  }

  @override
  Future<bool> updateDeviceName(String deviceId, String name) async {
    _ensureInitialized();
    _ensureAuthenticated();

    // Validate name
    final trimmedName = name.trim();
    if (trimmedName.isEmpty || trimmedName.length > 255) {
      debugPrint('[DeviceService] ❌ Invalid device name: must be 1-255 chars');
      return false;
    }

    try {
      await _supabase
          .from('devices')
          .update({'device_name': trimmedName})
          .eq('id', deviceId);

      debugPrint('[DeviceService] ✅ Device name updated to: $trimmedName');

      // Invalidate cache since device was updated
      _invalidateCache();

      return true;
    } on PostgrestException catch (e) {
      debugPrint(
        '[DeviceService] ❌ Postgres error updating device name: ${e.message}',
      );
      return false;
    } on Exception catch (e) {
      debugPrint('[DeviceService] ❌ Failed to update device name: $e');
      return false;
    }
  }

  @override
  Future<bool> removeDevice(String deviceId) async {
    _ensureInitialized();
    _ensureAuthenticated();

    // Prevent removing current device
    if (deviceId == _currentDeviceId) {
      debugPrint('[DeviceService] ❌ Cannot remove current device');
      return false;
    }

    try {
      await _supabase.from('devices').delete().eq('id', deviceId);

      debugPrint('[DeviceService] ✅ Device removed (ID: $deviceId)');

      // Invalidate cache since device was removed
      _invalidateCache();

      return true;
    } on PostgrestException catch (e) {
      debugPrint(
        '[DeviceService] ❌ Postgres error removing device: ${e.message}',
      );
      return false;
    } on Exception catch (e) {
      debugPrint('[DeviceService] ❌ Failed to remove device: $e');
      return false;
    }
  }

  @override
  String? getCurrentDeviceId() {
    return _currentDeviceId;
  }

  @override
  void dispose() {
    debugPrint('[DeviceService] Disposing service...');
    _initialized = false;
    _currentDeviceId = null;
    _lastActiveUpdateTime = null;
    _invalidateCache();
    debugPrint('[DeviceService] ✅ Disposed (cache cleared, all state reset)');
  }

  /// Check if cached device list is still valid
  bool _isCacheValid() {
    return _cachedDevices != null &&
        _lastDeviceFetch != null &&
        DateTime.now().difference(_lastDeviceFetch!) < _cacheExpiry;
  }

  /// Invalidate the device cache
  void _invalidateCache() {
    _cachedDevices = null;
    _lastDeviceFetch = null;
    debugPrint('[DeviceService] Cache invalidated');
  }
}
