import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghostcopy/models/exceptions.dart';
import 'package:ghostcopy/utils/network_errors.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  test('what an offline device actually throws counts as no connection', () {
    // Offline, the Supabase client throws http's ClientException wrapping the
    // socket error, not a SocketException - which is why the old mapping
    // missed it and a send said "Failed to send: ... Failed host lookup".
    for (final error in <Object>[
      http.ClientException('Failed host lookup: example.supabase.co'),
      const SocketException('Network is unreachable'),
      TimeoutException('no response'),
      AuthRetryableFetchException(),
      const FunctionsFetchException(details: 'Failed host lookup'),
      NetworkException(noInternetMessage),
    ]) {
      expect(isNetworkError(error), isTrue, reason: '$error');
      expect(sendFailureMessage(error, 'fallback'), noInternetMessage);
    }
  });

  test('a refusal from the server is not a connection problem', () {
    for (final error in <Object>[
      const PostgrestException(message: 'rate limited', code: 'P0001'),
      ValidationException('too long'),
      StateError('bug'),
    ]) {
      expect(isNetworkError(error), isFalse, reason: '$error');
      expect(sendFailureMessage(error, 'fallback'), 'fallback');
    }
  });
}
