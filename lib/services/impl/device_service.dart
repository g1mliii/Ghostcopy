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

  /// Free this device's push token from whatever row still holds it.
  ///
  /// Runs BEFORE the upsert, and that ordering is the whole point.
  /// `devices_fcm_token_global_unique` is a GLOBAL unique index on fcm_token,
  /// so inserting the renamed row while the old row still owns the token fails
  /// with 23505 - and this cleanup used to run after the upsert, which the
  /// failure skipped. Adding the install id to the device name makes every
  /// existing install a rename on first launch, so that deadlock would have
  /// hit all of them: registration failing every time, with nothing able to
  /// break it.
  ///
  /// Matched on the token rather than the old name. The token is globally
  /// unique, so a row carrying it can only be this installation - narrower and
  /// safer than a name match, which could belong to another phone still on the
  /// previous build, and which misses rows left under any other stale name.
  /// With the install id in play there are now two such names to outgrow: the
  /// generic platform label, and the model-only name before it.
  ///
  /// Rows already named for this device are left alone, so the upsert updates
  /// them in place and keeps their id.
  Future<void> _releaseTokenFromStaleRows({
    required String userId,
    required String currentName,
    required String? fcmToken,
  }) async {
    if (fcmToken == null || fcmToken.isEmpty) return;

    try {
      await _supabase
          .from('devices')
          .delete()
          .eq('user_id', userId)
          .eq('fcm_token', fcmToken)
          .neq('device_name', currentName);
    } on Object catch (e) {
      // Best effort. If it fails the upsert reports the conflict, and
      // registration is non-critical either way.
      debugPrint('[DeviceService] Could not free the stale token row: $e');
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

      await _releaseTokenFromStaleRows(
        userId: userId,
        currentName: deviceName,
        fcmToken: fcmToken,
      );

      // Upsert device (insert or update if exists)
      // Unique constraint on (user_id, device_type, device_name) ensures no duplicates
      final response = await _supabase
          .from('devices')
          .upsert({
            'user_id': userId,
            'device_type': deviceType,
            'device_name': deviceName,
            // Only with a token. An upsert updates every column it is given,
            // so sending null wiped the stored token whenever this launch had
            // not got one yet - a slow FCM answer, or iOS still waiting on
            // APNs - and push stayed off until a later launch put it back.
            // Left out, an existing row keeps its token and a new row starts
            // without one. Mobile callers pass their token here so
            // registration is a single write.
            if (fcmToken != null && fcmToken.isNotEmpty) 'fcm_token': fcmToken,
            'last_active': DateTime.now().toUtc().toIso8601String(),
          }, onConflict: 'user_id,device_type,device_name')
          .select('id')
          .single();

      _currentDeviceId = response['id'] as String;

      debugPrint(
        '[DeviceService] ✅ Device registered successfully (ID: $_currentDeviceId)',
      );

      // Invalidate cache since device list changed
      _invalidateCache();
      return true;
    } on PostgrestException catch (e) {
      if (e.code == '23505' && fcmToken != null) {
        // The token is still on a row of an account this install has left,
        // and the single upsert cannot take it - so the whole registration
        // failed and the device had no row at all. Register without it, then
        // claim it through updateFcmToken's server-side reclaim.
        debugPrint(
          '[DeviceService] ⚠️ Token held by another account - registering '
          'first, then reclaiming it',
        );
        // Success means the token landed, not just the row: callers such as
        // _reassertFcmToken stop retrying on true.
        final registered = await registerCurrentDevice();
        return registered && await _applyFcmToken(fcmToken);
      }
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
    await _applyFcmToken(fcmToken);
  }

  /// Put [fcmToken] on this device's row; true only if it is there after.
  ///
  /// Registration needs the answer, not just the attempt: when its upsert
  /// hit a token conflict it used to report success whatever the reclaim
  /// did, and MobileMainViewModel._reassertFcmToken - which retries only on
  /// failure - then stopped trying for an hour with no token on the row.
  Future<bool> _applyFcmToken(String fcmToken) async {
    _ensureInitialized();
    _ensureAuthenticated();

    if (_currentDeviceId == null) {
      debugPrint(
        '[DeviceService] ⚠️ Cannot update FCM token: device not registered',
      );
      return false;
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
      return true;
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
        // A plain delete-and-retry cannot work: RLS limits the caller to its
        // own rows, and the row holding the token belongs to the account this
        // install left. claim_fcm_token does it server-side, moving the token
        // only into a row the caller owns.
        try {
          final claimed = await _supabase.rpc<bool>(
            'claim_fcm_token',
            params: {'p_device_id': _currentDeviceId, 'p_token': fcmToken},
          );
          debugPrint(
            claimed
                ? '[DeviceService] ✅ FCM token reclaimed'
                : '[DeviceService] ❌ FCM token not reclaimed - this device row '
                      'is not on the signed-in account',
          );
          return claimed;
        } on Exception catch (retryError) {
          debugPrint(
            '[DeviceService] ❌ Could not reclaim FCM token - push will not '
            'arrive on this device: $retryError',
          );
          return false;
        }
      }
      debugPrint(
        '[DeviceService] ❌ Postgres error updating FCM token: ${e.message}',
      );
    } on Exception catch (e) {
      debugPrint('[DeviceService] ❌ Failed to update FCM token: $e');
    }
    return false;
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
