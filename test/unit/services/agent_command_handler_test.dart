import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghostcopy/models/clipboard_item.dart';
import 'package:ghostcopy/models/exceptions.dart';
import 'package:ghostcopy/repositories/clipboard_repository.dart';
import 'package:ghostcopy/services/account_prompt_store.dart';
import 'package:ghostcopy/services/agent_command_handler.dart';
import 'package:ghostcopy/services/auth_service.dart';
import 'package:ghostcopy/services/device_service.dart';
import 'package:ghostcopy/services/settings_service.dart';
import 'package:ghostcopy/services/single_instance.dart';
import 'package:ghostcopy_agent/agent_protocol.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Auth extends Mock implements IAuthService {}

class _Clips extends Mock implements IClipboardRepository {}

class _Devices extends Mock implements IDeviceService {}

class _Settings extends Mock implements ISettingsService {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    registerFallbackValue(
      ClipboardItem(
        id: 'fallback',
        userId: 'u',
        content: 'x',
        deviceType: 'windows',
        createdAt: DateTime(2026),
      ),
    );
  });

  late _Auth auth;
  late _Clips clips;
  late _Devices devices;
  late _Settings settings;
  late List<(String, List<String>?)> filesSent;
  late AgentCommandHandler handler;

  setUp(() {
    auth = _Auth();
    clips = _Clips();
    devices = _Devices();
    settings = _Settings();
    filesSent = [];
    when(() => settings.getAgentAccessEnabled()).thenAnswer((_) async => true);
    when(
      () => settings.getAutoSendTargetDevices(),
    ).thenAnswer((_) async => <String>{});
    when(() => auth.currentUserId).thenReturn('user-1');
    when(() => clips.insert(any())).thenAnswer(
      (call) async => call.positionalArguments.single as ClipboardItem,
    );
    handler = AgentCommandHandler(
      authService: auth,
      clipboardRepository: clips,
      deviceService: devices,
      settingsService: settings,
      sendFile: (path, targets) async {
        filesSent.add((path, targets));
        return (ok: true, message: 'Sent notes.txt to your other devices.');
      },
    );
  });

  ClipboardItem inserted() =>
      verify(() => clips.insert(captureAny())).captured.single as ClipboardItem;

  test('nothing happens until the user turns it on', () async {
    when(() => settings.getAgentAccessEnabled()).thenAnswer((_) async => false);

    final reply = await handler.handle({'name': 'send_text', 'text': 'hi'});

    expect(reply['ok'], isFalse);
    expect(reply['error'], 'disabled');
    expect(reply['message'], contains('Command line & AI tools'));
    verifyNever(() => clips.insert(any()));
  });

  test('signed out is refused', () async {
    when(() => auth.currentUserId).thenReturn(null);
    final reply = await handler.handle({'name': 'list_devices'});
    expect(reply['error'], 'signed_out');
  });

  test('text goes to the default devices when none are named', () async {
    when(
      () => settings.getAutoSendTargetDevices(),
    ).thenAnswer((_) async => {'ios'});

    final reply = await handler.handle({'name': 'send_text', 'text': 'hi'});

    expect(reply, containsPair('ok', true));
    expect(reply['status'], 'sent');
    final item = inserted();
    expect(item.targetDeviceTypes, ['ios']);
    expect(item.userId, 'user-1');
  });

  test('a text send counts toward the guest account offer', () async {
    SharedPreferences.setMockInitialValues({});
    final store = await AccountPromptStore.open();
    final counting = AgentCommandHandler(
      authService: auth,
      clipboardRepository: clips,
      deviceService: devices,
      settingsService: settings,
      sendFile: (path, targets) async => (ok: true, message: ''),
      accountPromptStore: store,
    );

    await counting.handle({'name': 'send_text', 'text': 'hi'});

    expect(store.hasSent, isTrue);
  });

  test(
    'a send that worked is reported as sent even if the bookkeeping fails',
    () async {
      SharedPreferences.setMockInitialValues({});
      final failing = _FailingPromptStore(
        await SharedPreferences.getInstance(),
      );
      final counting = AgentCommandHandler(
        authService: auth,
        clipboardRepository: clips,
        deviceService: devices,
        settingsService: settings,
        sendFile: (path, targets) async => (ok: true, message: ''),
        accountPromptStore: failing,
      );

      final reply = await counting.handle({'name': 'send_text', 'text': 'hi'});

      // Reported as failed, a caller would retry and send it twice.
      expect(reply['ok'], isTrue);
    },
  );

  test('a device list that could not load is not "no devices"', () async {
    when(() => devices.getCurrentDeviceId()).thenReturn('d1');
    when(() => devices.fetchUserDevices()).thenAnswer((_) async => null);

    final reply = await handler.handle({'name': 'list_devices'});

    expect(reply['ok'], isFalse);
    expect(reply['message'], contains('Could not load your devices'));
  });

  test('an account with no devices registered is a true empty list', () async {
    // Startup lets a desktop run when its own registration failed.
    when(() => devices.getCurrentDeviceId()).thenReturn(null);
    when(() => devices.fetchUserDevices()).thenAnswer((_) async => []);

    final reply = await handler.handle({'name': 'list_devices'});

    expect(reply['ok'], isTrue);
    expect(reply['devices'], isEmpty);
  });

  test('an empty default setting means every device', () async {
    final reply = await handler.handle({'name': 'send_text', 'text': 'hi'});
    expect(reply['to'], 'all');
    expect(inserted().targetDeviceTypes, isNull);
  });

  test('named devices win over the setting', () async {
    when(
      () => settings.getAutoSendTargetDevices(),
    ).thenAnswer((_) async => {'windows'});

    await handler.handle({
      'name': 'send_text',
      'text': 'hi',
      'to': ['phone'],
    });

    expect(inserted().targetDeviceTypes, ['android', 'ios']);
  });

  test('a rejected clip is a refusal, an offline one a failure', () async {
    when(() => clips.insert(any())).thenThrow(ValidationException('Too long'));
    expect(
      (await handler.handle({'name': 'send_text', 'text': 'hi'}))['error'],
      'bad_request',
    );

    when(
      () => clips.insert(any()),
    ).thenThrow(const SocketException('Failed host lookup'));
    final offline = await handler.handle({'name': 'send_text', 'text': 'hi'});
    expect(offline['error'], 'send_failed');
  });

  test('files go through the shared file path with the targets', () async {
    final reply = await handler.handle({
      'name': 'send_file',
      'path': '/tmp/notes.txt',
      'to': ['mac'],
    });
    expect(reply['ok'], isTrue);
    expect(filesSent.single.$1, '/tmp/notes.txt');
    expect(filesSent.single.$2, ['macos']);
  });

  test('devices list marks this one', () async {
    when(() => devices.getCurrentDeviceId()).thenReturn('d2');
    when(() => devices.fetchUserDevices()).thenAnswer(
      (_) async => [
        Device(
          id: 'd1',
          userId: 'user-1',
          deviceType: 'ios',
          deviceName: 'iPhone',
          lastActive: DateTime.utc(2026, 10),
          createdAt: DateTime.utc(2026),
        ),
        Device(
          id: 'd2',
          userId: 'user-1',
          deviceType: 'macos',
          deviceName: 'Mac',
          lastActive: DateTime.utc(2026, 10),
          createdAt: DateTime.utc(2026),
        ),
      ],
    );

    final reply = await handler.handle({'name': 'list_devices'});

    final listed = reply['devices']! as List<Map<String, Object?>>;
    expect(listed.map((d) => d['this_device']), [false, true]);
    expect(listed.first['type'], 'ios');
  });

  test('bad input never reaches the repository', () async {
    for (final command in [
      {'name': 'send_text', 'text': ''},
      {
        'name': 'send_text',
        'text': 'hi',
        'to': ['toaster'],
      },
      {'name': 'send_file'},
      {'name': 'format_disk'},
    ]) {
      final reply = await handler.handle(command);
      expect(reply['error'], 'bad_request', reason: '$command');
    }
    verifyNever(() => clips.insert(any()));
    expect(filesSent, isEmpty);
  });

  // The whole path the command line takes: AgentClient's real handshake, over
  // the real loopback socket, into a primary SingleInstance and back.
  test('the command line reaches the running app and hears back', () async {
    final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final realPort = SingleInstance.port;
    SingleInstance.port = probe.port;
    await probe.close();
    final instance = SingleInstance.instance;
    addTearDown(() async {
      instance.commandHandler = null;
      await instance.disposeForTest();
      SingleInstance.port = realPort;
    });

    expect(await instance.acquire(const <String>[]), isTrue);
    final secretFile = File(
      '${Directory.systemTemp.createTempSync('agent').path}/secret',
    )..writeAsStringSync(instance.secret!);

    final client = AgentClient(
      port: SingleInstance.port,
      secretPath: secretFile.path,
    );

    // Before main.dart wires the handler: told so, not left hanging.
    expect(
      (await client.request({'name': 'list_devices'}))['error'],
      'not_ready',
    );

    instance.commandHandler = handler.handle;
    final reply = await client.request({'name': 'send_text', 'text': 'hello'});
    expect(reply['ok'], isTrue);
    expect(inserted().content, 'hello');

    // The wrong secret is not answered at all.
    secretFile.writeAsStringSync(base64Url.encode(List.filled(32, 7)));
    await expectLater(
      client.request({'name': 'list_devices'}),
      throwsA(isA<AgentException>().having((e) => e.code, 'code', 'no_answer')),
    );
  });
}

class _FailingPromptStore extends AccountPromptStore {
  _FailingPromptStore(super.prefs);

  @override
  Future<void> recordSend() async => throw Exception('disk full');
}
