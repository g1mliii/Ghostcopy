import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghostcopy/models/clip_link.dart';
import 'package:ghostcopy/models/clipboard_item.dart';
import 'package:ghostcopy/ui/widgets/clip_link_action.dart';
import 'package:url_launcher_platform_interface/link.dart';
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';

class _FakeLauncher extends UrlLauncherPlatform {
  final launched = <(String, PreferredLaunchMode)>[];
  Exception? failWith;
  bool result = true;

  @override
  LinkDelegate? get linkDelegate => null;

  @override
  Future<bool> canLaunch(String url) async => true;

  @override
  Future<bool> launchUrl(String url, LaunchOptions options) async {
    if (failWith != null) throw failWith!;
    launched.add((url, options.mode));
    return result;
  }
}

ClipboardItem _item(String content, ContentType type) => ClipboardItem(
  id: '1',
  userId: 'u',
  content: content,
  deviceType: 'macos',
  createdAt: DateTime(2026),
  contentType: type,
);

void main() {
  late _FakeLauncher launcher;

  setUp(() {
    launcher = _FakeLauncher();
    UrlLauncherPlatform.instance = launcher;
  });

  tearDown(() => debugDefaultTargetPlatformOverride = null);

  test('opens a map link the way this platform answers it', () async {
    final link = ClipLink.detect(
      'https://maps.apple.com/?q=CN%20Tower&ll=43.6426,-79.3871',
    )!;

    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    expect(await openClipLink(link), isTrue);
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    expect(await openClipLink(link), isTrue);

    expect(launcher.launched, [
      (
        'geo:43.6426,-79.3871?q=CN+Tower',
        PreferredLaunchMode.externalApplication,
      ),
      (link.uri.toString(), PreferredLaunchMode.externalApplication),
    ]);
  });

  test('reports a link nothing would open', () async {
    final link = ClipLink.detect('someone@example.com')!;

    launcher.result = false;
    expect(await openClipLink(link), isFalse);

    launcher.failWith = Exception('no handler');
    expect(await openClipLink(link), isFalse);
  });

  test('no Call button on Linux', () {
    final phone = ClipLink.detect('+1 416 555 0199')!;
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    expect(canOpenClipLink(phone), isFalse);
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    expect(canOpenClipLink(phone), isTrue);
  });

  test('only plain-text clips are links', () {
    expect(
      clipLinkFor(_item('https://example.com', ContentType.text)),
      isNotNull,
    );
    expect(clipLinkFor(_item('https://example.com', ContentType.html)), isNull);
    expect(
      clipLinkFor(_item('https://example.com', ContentType.markdown)),
      isNull,
    );
    expect(clipLinkFor(_item('hello', ContentType.text)), isNull);
  });

  test('the second action texts the number or finds the song', () async {
    final phone = ClipLink.detect('+1 416 555 0199')!;
    final song = ClipLink.detect('https://music.apple.com/ca/album/x/1')!;
    expect(await openClipLink(phone, alternate: true), isTrue);
    expect(await openClipLink(song, alternate: true), isTrue);
    expect(launcher.launched.map((l) => l.$1), [
      'sms:+14165550199',
      'https://song.link/https://music.apple.com/ca/album/x/1',
    ]);

    // Nothing second to do with a web link.
    expect(
      await openClipLink(ClipLink.detect('https://a.com')!, alternate: true),
      isFalse,
    );

    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    expect(canAlternateClipLink(phone), isFalse);
    expect(canAlternateClipLink(song), isTrue);
  });
}
