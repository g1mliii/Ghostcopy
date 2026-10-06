import 'package:supabase_flutter/supabase_flutter.dart';

import 'network_errors.dart';

/// What to tell a person when signing in, signing up or resetting a password
/// fails.
///
/// The sign-in screens used to show `error.toString()`, which for Supabase is
/// "AuthException(message: Invalid login credentials, statusCode: 400, ...)".
/// The common cases get a sentence that says what to do; anything else gets
/// the server's own message, which is written for people, without the
/// wrapper.
String authErrorMessage(Object error) {
  if (isNetworkError(error)) return noInternetMessage;
  if (error is! AuthException) {
    // Our own Exception('...') messages are already written for people.
    return error.toString().replaceFirst('Exception: ', '');
  }

  final message = error.message.toLowerCase();
  switch (error.code) {
    case 'invalid_credentials':
      return _wrongCredentials;
    case 'email_not_confirmed':
      return _emailNotConfirmed;
    case 'user_already_exists':
    case 'email_exists':
      return _accountExists;
    case 'over_request_rate_limit':
    case 'over_email_send_rate_limit':
      return _tooManyAttempts;
    case 'email_address_invalid':
    case 'validation_failed':
      if (message.contains('email')) return _invalidEmail;
    case 'user_banned':
      return 'This account has been suspended.';
  }

  // Older servers send no code; their messages are stable.
  if (message.contains('invalid login credentials')) return _wrongCredentials;
  if (message.contains('email not confirmed')) return _emailNotConfirmed;
  if (message.contains('already registered')) return _accountExists;
  if (error.statusCode == '429') return _tooManyAttempts;

  return error.message.isEmpty
      ? 'Something went wrong. Please try again.'
      : error.message;
}

const _wrongCredentials =
    "That email and password don't match. Check them and try again, or use "
    'Forgot Password.';
const _emailNotConfirmed =
    'Confirm your email first - open the link we sent you, then log in.';
const _accountExists =
    'An account with this email already exists. Log in instead.';
const _tooManyAttempts = 'Too many attempts. Wait a minute and try again.';
const _invalidEmail = 'Enter a valid email address.';
