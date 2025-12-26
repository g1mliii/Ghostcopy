import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../repositories/clipboard_repository.dart';
import '../device_service.dart';

/// Concrete implementation of IDeviceService
///
/// Manages device registration and tracking in Supabase.
/// Desktop devices register without FCM tokens.
/// Mobile devices will add FCM tokens when implemented.
class DeviceService implements IDeviceService {
  final SupabaseClient _supabase = Supabase.instance.client;
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
      debugPrint('[DeviceService] ✅ Initialized successfully (caching enabled: 5min TTL)');
    } on Exception catch (e) {
      debugPrint('[DeviceService] ❌ Failed to initialize: $e');
      rethrow;
    }
  }

  void _ensureInitialized() {
    if (!_initialized) {
      throw StateError('DeviceService not initialized. Call initialize() first.');
    }
  }

  void _ensureAuthenticated() {
    if (_supabase.auth.currentUser == null) {
      throw StateError('User not authenticated. Cannot register device.');
    }
  }

  @override
  Future<void> registerCurrentDevice() async {
    _ensureInitialized();
    _ensureAuthenticated();

    try {
      final userId = _supabase.auth.currentUser!.id;
      final deviceType = ClipboardRepository.getCurrentDeviceType();
      final deviceName = ClipboardRepository.getCurrentDeviceName() ??
          '${_capitalizeFirst(deviceType)} Device';

      debugPrint('[DeviceService] Registering device: $deviceType ($deviceName)');

      // Upsert device (insert or update if exists)
      // Unique constraint on (user_id, device_type, device_name) ensures no duplicates
      final response = await _supabase.from('devices').upsert(
        {
          'user_id': userId,
          'device_type': deviceType,
          'device_name': deviceName,
          'fcm_token': null, // Desktop doesn't use FCM, mobile will update later
          'last_active': DateTime.now().toUtc().toIso8601String(),
        },
        onConflict: 'user_id,device_type,device_name',
      ).select('id').single();

      _currentDeviceId = response['id'] as String;

      debugPrint(
        '[DeviceService] ✅ Device registered successfully (ID: $_currentDeviceId)',
      );

      // Invalidate cache since device list changed
      _invalidateCache();
    } on PostgrestException catch (e) {
      debugPrint('[DeviceService] ❌ Postgres error registering device: ${e.message}');
      // Don't rethrow - device registration is non-critical
    } on Exception catch (e) {
      debugPrint('[DeviceService] ❌ Failed to register device: $e');
      // Don't rethrow - device registration is non-critical
    }
  }

  @override
  Future<List<Device>> getUserDevices({bool forceRefresh = false}) async {
    _ensureInitialized();
    _ensureAuthenticated();

    // Check cache first (unless force refresh requested)
    if (!forceRefresh && _isCacheValid()) {
      debugPrint('[DeviceService] Returning cached devices (${_cachedDevices!.length} device(s))');
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

      debugPrint('[DeviceService] Fetched and cached ${devices.length} device(s)');

      return devices;
    } on PostgrestException catch (e) {
      debugPrint('[DeviceService] ❌ Postgres error fetching devices: ${e.message}');
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
      await _supabase.from('devices').update({
        'fcm_token': fcmToken,
        'last_active': DateTime.now().toUtc().toIso8601String(),
      }).eq('id', _currentDeviceId!);

      debugPrint('[DeviceService] ✅ FCM token updated');
    } on PostgrestException catch (e) {
      debugPrint('[DeviceService] ❌ Postgres error updating FCM token: ${e.message}');
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
        DateTime.now().difference(_lastActiveUpdateTime!) < _minActiveUpdateInterval) {
      debugPrint(
        '[DeviceService] ⏭️ Skipping last active update (rate limited)',
      );
      return;
    }

    try {
      await _supabase.from('devices').update({
        'last_active': DateTime.now().toUtc().toIso8601String(),
      }).eq('id', _currentDeviceId!);

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
      debugPrint('[DeviceService] ❌ Postgres error unregistering device: ${e.message}');
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
      await _supabase.from('devices').update({
        'device_name': trimmedName,
      }).eq('id', deviceId);

      debugPrint('[DeviceService] ✅ Device name updated to: $trimmedName');

      // Invalidate cache since device was updated
      _invalidateCache();

      return true;
    } on PostgrestException catch (e) {
      debugPrint('[DeviceService] ❌ Postgres error updating device name: ${e.message}');
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
      debugPrint('[DeviceService] ❌ Postgres error removing device: ${e.message}');
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

  /// Capitalize first letter of a string
  String _capitalizeFirst(String text) {
    if (text.isEmpty) return text;
    return text[0].toUpperCase() + text.substring(1);
  }
}
