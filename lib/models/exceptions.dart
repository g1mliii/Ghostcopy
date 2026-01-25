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
