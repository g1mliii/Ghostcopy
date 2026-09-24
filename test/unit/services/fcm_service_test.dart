import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghostcopy/services/impl/fcm_service.dart';
import 'package:mocktail/mocktail.dart';

class _Messaging extends Mock implements FirebaseMessaging {}

class _Settings extends Mock implements NotificationSettings {}

void main() {
  late _Messaging messaging;
  late List<Duration> waits;

  FcmService service({required bool isIOS}) => FcmService(
    messaging: messaging,
    isIOS: isIOS,
    delay: (d) async => waits.add(d),
  );

  setUp(() {
    messaging = _Messaging();
    waits = [];
    final settings = _Settings();
    when(
      () => settings.authorizationStatus,
    ).thenReturn(AuthorizationStatus.authorized);
    when(messaging.requestPermission).thenAnswer((_) async => settings);
    when(
      () => messaging.onTokenRefresh,
    ).thenAnswer((_) => const Stream.empty());
  });

  test('iOS waits for the APNs token before asking FCM', () async {
    // A first launch asks straight after the permission prompt, before APNs
    // has answered; FCM had no token to give and the device registered
    // without one, so push stayed off until the next launch.
    var apnsAsks = 0;
    when(messaging.getAPNSToken).thenAnswer((_) async {
      return ++apnsAsks < 3 ? null : 'apns';
    });
    when(messaging.getToken).thenAnswer((_) async {
      expect(apnsAsks, 3, reason: 'FCM was asked before APNs answered');
      return 'fcm-token';
    });
    final fcm = service(isIOS: true);
    await fcm.initialize();

    expect(await fcm.getToken(), 'fcm-token');
    expect(apnsAsks, 3);
  });

  test('a failed token request is retried', () async {
    var asks = 0;
    when(messaging.getToken).thenAnswer((_) async {
      if (asks++ == 0) throw Exception('network blip');
      return 'fcm-token';
    });
    final fcm = service(isIOS: false);
    await fcm.initialize();

    expect(await fcm.getToken(), 'fcm-token');
    expect(asks, 2);
    verifyNever(messaging.getAPNSToken);
  });

  test('gives up after a few tries rather than blocking', () async {
    when(messaging.getToken).thenAnswer((_) async => null);
    final fcm = service(isIOS: false);
    await fcm.initialize();

    expect(await fcm.getToken(), isNull);
    verify(messaging.getToken).called(3);
  });
}
