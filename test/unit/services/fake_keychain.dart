import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:mocktail/mocktail.dart';

/// A Keychain with the two behaviours that caused the original incident.
///
/// Stubbing call-by-call would let these tests pass against a migration that
/// only works because the stubs were written to match it. The rules modelled
/// here are the ones that actually bite:
///
///  1. An item is identified by key alone. Accessibility is an attribute, not
///     part of that identity, so the old and new items can never coexist - and
///     an add on top of an existing item fails, whatever its accessibility.
///     That is errSecDuplicateItem (-25299), the write half of the incident.
///  2. A read carries accessibility in its query, so an item written under one
///     value is invisible to a read under another. That is the read half: "No
///     existing passphrase found" about an item that is demonstrably there.
class FakeKeychain extends Mock implements FlutterSecureStorage {
  final Map<String, (String value, KeychainAccessibility accessibility)> items =
      {};

  /// Keys whose next write throws, to exercise the window where the value
  /// exists only on the stack.
  final Set<String> failWritesFor = {};

  /// Simulates a successful write that does not persist its value.
  final Set<String> dropWritesFor = {};

  /// Every read, so the test below can hold the Keychain round trips down.
  int reads = 0;

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    reads++;
    final item = items[key];
    if (item == null) return null;
    return item.$2 == iOptions?.accessibility ? item.$1 : null;
  }

  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (failWritesFor.remove(key)) {
      throw Exception('simulated secure-storage failure');
    }
    if (dropWritesFor.remove(key)) return;
    if (items.containsKey(key)) {
      throw Exception('-25299 duplicate item');
    }
    items[key] = (
      value!,
      iOptions?.accessibility ?? KeychainAccessibility.unlocked,
    );
  }

  @override
  Future<void> delete({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (items[key]?.$2 == iOptions?.accessibility) items.remove(key);
  }

  /// Makes the next deleteAll throw.
  bool failDeleteAll = false;

  /// Everything, whatever its accessibility: flutter_secure_storage_darwin
  /// deletes without an accessibility constraint (performDelete clears it).
  @override
  Future<void> deleteAll({
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (failDeleteAll) throw Exception('simulated secure-storage failure');
    items.clear();
  }
}
