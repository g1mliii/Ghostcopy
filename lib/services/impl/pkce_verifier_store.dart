import 'package:supabase_flutter/supabase_flutter.dart';

/// Where Supabase keeps the PKCE code verifier, handed to it as
/// `pkceAsyncStorage` so the app can make it forget one.
///
/// gotrue stores a verifier each time a browser or email flow starts, and
/// needs it to redeem the code the callback brings back. AuthService calls
/// [forget] when a browser sign-in is abandoned, so a callback arriving after
/// the app has reported failure can no longer switch accounts behind it.
///
/// It forgets by clearing every key gotrue wrote here, not by naming the key:
/// that name is gotrue's own constant, not part of its API, and deleting a
/// renamed key would do nothing without any error. Everything gotrue writes to
/// this storage is PKCE state, so clearing all of it is exactly the job.
class PkceVerifierStore extends GotrueAsyncStorage {
  /// Backed by [inner], or by SharedPreferences - what Supabase uses when it
  /// is given no storage of its own.
  PkceVerifierStore([GotrueAsyncStorage? inner])
    : _inner = inner ?? SharedPreferencesGotrueAsyncStorage();

  final GotrueAsyncStorage _inner;

  /// Keys gotrue has written in this process and not removed since.
  final _written = <String>{};

  @override
  Future<String?> getItem({required String key}) => _inner.getItem(key: key);

  @override
  Future<void> setItem({required String key, required String value}) {
    _written.add(key);
    return _inner.setItem(key: key, value: value);
  }

  @override
  Future<void> removeItem({required String key}) {
    _written.remove(key);
    return _inner.removeItem(key: key);
  }

  /// Drop the verifier of any flow still waiting for its callback.
  Future<void> forget() async {
    final keys = _written.toList();
    _written.clear();
    for (final key in keys) {
      await _inner.removeItem(key: key);
    }
  }
}
