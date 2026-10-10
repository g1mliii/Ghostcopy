import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghostcopy/utils/auth_errors.dart';
import 'package:ghostcopy/utils/network_errors.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  test('wrong email or password says so, not "400"', () {
    final message = authErrorMessage(
      const AuthException(
        'Invalid login credentials',
        statusCode: '400',
        code: 'invalid_credentials',
      ),
    );
    expect(message, contains("don't match"));
    expect(message, isNot(contains('400')));
    expect(message, isNot(contains('AuthException')));
  });

  test('older servers without a code are recognised by the message', () {
    expect(
      authErrorMessage(
        const AuthException('Invalid login credentials', statusCode: '400'),
      ),
      contains("don't match"),
    );
  });

  test('the common cases each say what to do', () {
    String of(String code, [String message = 'x']) =>
        authErrorMessage(AuthException(message, code: code));
    expect(of('email_not_confirmed'), contains('Confirm your email'));
    expect(of('user_already_exists'), contains('already exists'));
    expect(of('over_request_rate_limit'), contains('Too many attempts'));
    expect(
      of('validation_failed', 'Unable to validate email address'),
      'Enter a valid email address.',
    );
  });

  test('anything else keeps the server message, without the wrapper', () {
    expect(
      authErrorMessage(
        const AuthException('Password should be at least 6 characters'),
      ),
      'Password should be at least 6 characters',
    );
  });

  test('offline says no internet', () {
    expect(
      authErrorMessage(const SocketException('Failed host lookup')),
      noInternetMessage,
    );
  });

  test('our own messages pass through', () {
    expect(
      authErrorMessage(Exception('The server did not return a session.')),
      'The server did not return a session.',
    );
  });
}
