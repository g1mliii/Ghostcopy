import 'package:supabase_flutter/supabase_flutter.dart';

import 'auth_service.dart';

/// Signs this device into the account a device link (QR code or pasted link
/// code) belongs to, using the 6-digit PIN shown beside it.
///
/// Shared by the welcome screen's QR scanner and account recovery. A wrong PIN
/// does not consume the link server-side, so callers can let the user retype.
/// Throws on failure; [describeLinkExchangeError] turns that into text.
Future<void> exchangeLinkToken({
  required SupabaseClient client,
  required IAuthService auth,
  required String token,
  required String pin,
}) async {
  final response = await client.functions.invoke(
    'exchange-link-token',
    body: {'token': token, 'pin': pin},
  );
  // functions_client throws FunctionsHttpException for any non-2xx, so this
  // only sees a 2xx. Read the token defensively: a cast failure would be an
  // Error, not an Exception, and the single-use link is already spent.
  final data = response.data;
  final refreshToken = data is Map ? data['refresh_token'] : null;
  if (refreshToken is! String || refreshToken.isEmpty) {
    throw Exception(
      'The server did not return a session. Please generate a new QR code.',
    );
  }
  // Preserve the previous account until the new session is established.
  await auth.signInWithRefreshToken(refreshToken);
}

/// Turn a link-token exchange failure into something worth reading.
///
/// functions_client throws [FunctionsHttpException] for any non-2xx rather
/// than returning it, so the server's `code` lives in `details` - not in a
/// response the caller can inspect. Without unpacking it the user saw raw
/// exception text and the whole point of the server distinguishing a wrong
/// PIN from an expired code was lost.
///
/// A wrong PIN and an expired link always get their own message. Anything
/// else uses [fallback] when given, or the best text the error carries.
String describeLinkExchangeError(Object error, {String? fallback}) {
  if (error is FunctionsHttpException) {
    final details = error.details;
    final code = details is Map ? details['code'] : null;
    switch (code) {
      case 'invalid_pin':
        return 'Incorrect PIN. Check the code on your other device and '
            'try again.';
      case 'expired':
        return 'This code has expired or was already used. Generate a new '
            'QR code on your other device.';
    }
    if (fallback != null) return fallback;
    final message = details is Map ? details['error'] : null;
    if (message is String && message.isNotEmpty) return message;
    return 'Could not link this device. Please try again.';
  }
  return fallback ?? error.toString().replaceAll('Exception: ', '');
}
