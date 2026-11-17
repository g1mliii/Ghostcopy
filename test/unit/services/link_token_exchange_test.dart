import 'package:flutter_test/flutter_test.dart';
import 'package:ghostcopy/services/link_token_exchange.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  FunctionsHttpException failure(int status, Object? details) =>
      FunctionsHttpException(status: status, details: details);

  test('a wrong PIN and an expired link always get their own message', () {
    for (final fallback in [null, 'Could not link.']) {
      expect(
        describeLinkExchangeError(
          failure(401, {'error': 'Incorrect PIN', 'code': 'invalid_pin'}),
          fallback: fallback,
        ),
        startsWith('Incorrect PIN.'),
      );
      expect(
        describeLinkExchangeError(
          failure(410, {'error': 'gone', 'code': 'expired'}),
          fallback: fallback,
        ),
        startsWith('This code has expired'),
      );
    }
  });

  test('other failures use the fallback, or the best text available', () {
    final server = failure(500, {'error': 'Server is busy'});
    expect(describeLinkExchangeError(server), 'Server is busy');
    expect(
      describeLinkExchangeError(server, fallback: 'Could not link.'),
      'Could not link.',
    );
    expect(
      describeLinkExchangeError(failure(500, 'not json')),
      'Could not link this device. Please try again.',
    );
    expect(describeLinkExchangeError(Exception('Offline')), 'Offline');
    expect(
      describeLinkExchangeError(Exception('Offline'), fallback: 'Try later'),
      'Try later',
    );
  });
}
