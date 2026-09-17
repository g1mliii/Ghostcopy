/// Custom exceptions for repository layer
library;

/// Base exception for repository errors
class RepositoryException implements Exception {
  RepositoryException(this.message);

  final String message;

  @override
  String toString() => 'RepositoryException: $message';
}

/// Network-related errors (connectivity issues)
class NetworkException extends RepositoryException {
  NetworkException(super.message);

  @override
  String toString() => 'NetworkException: $message';
}

/// Validation errors (file too large, invalid input)
class ValidationException extends RepositoryException {
  ValidationException(super.message);

  @override
  String toString() => 'ValidationException: $message';
}

/// Storage-related errors (upload failures, access denied)
class RepositoryStorageException extends RepositoryException {
  RepositoryStorageException(super.message, {this.statusCode});

  final int? statusCode;

  @override
  String toString() =>
      'RepositoryStorageException: $message${statusCode != null ? ' (HTTP $statusCode)' : ''}';
}

/// Security/authentication errors
class SecurityException extends RepositoryException {
  SecurityException(super.message);

  @override
  String toString() => 'SecurityException: $message';
}

/// The device could not store the encryption passphrase.
///
/// Distinct from a passphrase being rejected. iOS keeps Keychain entries when
/// an app is deleted, so a reinstall can meet an item it cannot read but also
/// cannot overwrite (errSecDuplicateItem), and any change to how the key is
/// addressed does the same. Nothing about the passphrase itself is wrong, so
/// telling the user to check it and retry is both useless and alarming.
class PassphraseStorageException implements Exception {
  const PassphraseStorageException(this.message);

  final String message;

  @override
  String toString() => 'PassphraseStorageException: $message';
}
