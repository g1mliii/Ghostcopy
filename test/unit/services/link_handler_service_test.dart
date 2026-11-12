import 'dart:io';

import 'package:clock/clock.dart';
import 'package:flutter/painting.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghostcopy/models/clip_link.dart';
import 'package:ghostcopy/services/impl/link_handler_service.dart';
import 'package:ghostcopy/services/impl/windows_link_handler.dart';
import 'package:ghostcopy/services/link_handler_service.dart';
import 'package:ghostcopy/utils/xdg.dart';
import 'package:path/path.dart' as path;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ChannelLinkHandlerService', () {
    const channel = MethodChannel('test/link_handler');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    late List<String> asked;
    late Object? Function(String url) answer;

    setUp(() {
      asked = [];
      answer = (_) => null;
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'handlerFor');
        final url = (call.arguments as Map)['url'] as String;
        asked.add(url);
        return answer(url);
      });
    });

    tearDown(() => messenger.setMockMethodCallHandler(channel, null));

    test(
      'asks about the URI Open would launch, once per kind of link',
      () async {
        final icon = Uint8List.fromList([1, 2, 3]);
        answer = (url) => {'name': 'Google Maps', 'icon': icon};
        final service = ChannelLinkHandlerService(
          platform: 'android',
          channel: channel,
        );
        final first = ClipLink.detect(
          'https://maps.apple.com/?q=CN%20Tower&ll=43.6426,-79.3871',
        )!;
        final second = ClipLink.detect('https://maps.apple.com/?q=Union')!;

        expect(service.cachedHandlerFor(first), isNull);
        final handler = await service.handlerFor(first);
        expect(handler!.name, 'Google Maps');
        expect((handler.icon! as MemoryImage).bytes, icon);
        // Rewritten to geo: for Android, which is what tapping Open sends:
        // the pin, labelled with the place name.
        expect(asked, [
          'geo:43.6426,-79.3871?q=43.6426%2C-79.3871%28CN+Tower%29',
        ]);

        expect((await service.handlerFor(second))!.name, 'Google Maps');
        expect(asked, hasLength(1));
        expect(service.cachedHandlerFor(second)!.name, 'Google Maps');
      },
    );

    test('keeps a map link on google.com apart from a search there', () async {
      answer = (url) => {
        'name': url.contains('/maps') ? 'Google Maps' : 'Chrome',
      };
      final service = ChannelLinkHandlerService(
        platform: 'android',
        channel: channel,
      );
      final maps = await service.handlerFor(
        ClipLink.detect('https://www.google.com/maps/place/CN+Tower')!,
      );
      final search = await service.handlerFor(
        ClipLink.detect('https://www.google.com/search?q=cn+tower')!,
      );
      expect(maps!.name, 'Google Maps');
      expect(search!.name, 'Chrome');
      expect(search.icon, isNull);
    });

    test('one app is one LinkHandler, however many sites it opens', () async {
      answer = (_) => {
        'name': 'Safari',
        'icon': Uint8List.fromList([1]),
      };
      final service = ChannelLinkHandlerService(
        platform: 'macos',
        channel: channel,
      );
      final a = await service.handlerFor(ClipLink.detect('https://a.com')!);
      final b = await service.handlerFor(ClipLink.detect('https://b.org')!);
      expect(asked, hasLength(2));
      expect(identical(a, b), isTrue);
    });

    test(
      'no default, an error or no plugin all mean the generic glyph',
      () async {
        final link = ClipLink.detect('someone@example.com')!;

        answer = (_) => null;
        expect(
          await ChannelLinkHandlerService(
            platform: 'macos',
            channel: channel,
          ).handlerFor(link),
          isNull,
        );

        answer = (_) => throw PlatformException(code: 'boom');
        expect(
          await ChannelLinkHandlerService(
            platform: 'macos',
            channel: channel,
          ).handlerFor(link),
          isNull,
        );

        expect(
          await ChannelLinkHandlerService(
            platform: 'macos',
            channel: const MethodChannel('test/not_registered'),
          ).handlerFor(link),
          isNull,
        );
      },
    );
  });

  test('an expired lookup recovers a previously unreadable app icon', () async {
    var now = DateTime(2026);
    await withClock(Clock(() => now), () async {
      final service = _MutableHandlerService();
      final link = ClipLink.detect('https://example.com')!;
      final original = await service.handlerFor(link);
      expect(original!.icon, isNull);

      final icon = MemoryImage(Uint8List.fromList([1, 2, 3]));
      service.handler = LinkHandler(name: 'Browser', icon: icon);
      now = now.add(
        CachingLinkHandlerService.maxAge + const Duration(seconds: 1),
      );

      final refreshed = await service.handlerFor(link);
      expect(refreshed!.icon, same(icon));
      expect(service.cachedHandlerFor(link), same(refreshed));
    });
  });

  test('an expired lookup replaces an app icon at a new file path', () async {
    var now = DateTime(2026);
    await withClock(Clock(() => now), () async {
      final originalIcon = FileImage(File('/browser/v1/icon.png'));
      final service = _MutableHandlerService()
        ..handler = LinkHandler(name: 'Browser', icon: originalIcon);
      final link = ClipLink.detect('https://example.com')!;
      expect((await service.handlerFor(link))!.icon, same(originalIcon));

      final updatedIcon = FileImage(File('/browser/v2/icon.png'));
      service.handler = LinkHandler(name: 'Browser', icon: updatedIcon);
      now = now.add(
        CachingLinkHandlerService.maxAge + const Duration(seconds: 1),
      );

      final refreshed = await service.handlerFor(link);
      expect(refreshed!.icon, same(updatedIcon));
      expect(service.cachedHandlerFor(link), same(refreshed));
    });
  });

  group('LinuxLinkHandlerService', () {
    late Directory root;
    late Map<String, String> env;

    setUp(() {
      root = Directory.systemTemp.createTempSync('link_handler');
      // XDG_DATA_DIRS is colon-separated. A Windows drive prefix would be
      // parsed as another entry; root these fixtures on the current drive.
      final fixtureRoot = path.joinAll([
        path.separator,
        ...path.split(root.path).skip(1),
      ]);
      env = {
        'HOME': path.join(fixtureRoot, 'home'),
        'XDG_DATA_HOME': path.join(fixtureRoot, 'home', 'share'),
        'XDG_DATA_DIRS': path.join(fixtureRoot, 'usr', 'share'),
      };
    });

    tearDown(() => root.deleteSync(recursive: true));

    void write(String relative, String contents) {
      File('${root.path}/$relative')
        ..createSync(recursive: true)
        ..writeAsStringSync(contents);
    }

    LinuxLinkHandlerService service(String stdout, {int exitCode = 0}) {
      return LinuxLinkHandlerService(
        environment: env,
        runProcess: (executable, arguments) async {
          expect(executable, 'xdg-mime');
          expect(arguments, ['query', 'default', 'x-scheme-handler/https']);
          return ProcessResult(0, exitCode, stdout, '');
        },
      );
    }

    final web = ClipLink.detect('https://example.com')!;

    test('names the default app and finds its hicolor icon', () async {
      write('usr/share/applications/firefox.desktop', '''
[Desktop Entry]
Name[fr]=Firefox Navigateur
Name=Firefox
Icon=firefox

[Desktop Action new-window]
Name=New Window
''');
      write('usr/share/icons/hicolor/128x128/apps/firefox.png', 'png');
      write('usr/share/icons/hicolor/48x48/apps/firefox.png', 'small');

      final handler = await service('firefox.desktop\n').handlerFor(web);
      expect(handler!.name, 'Firefox');
      expect(
        path.normalize((handler.icon! as FileImage).file.absolute.path),
        path.join(
          root.path,
          'usr',
          'share',
          'icons',
          'hicolor',
          '128x128',
          'apps',
          'firefox.png',
        ),
      );
    });

    test('a user entry wins over the system one', () async {
      write(
        'usr/share/applications/browser.desktop',
        '[Desktop Entry]\nName=System\n',
      );
      write(
        'home/share/applications/browser.desktop',
        '[Desktop Entry]\nName=Mine\n',
      );
      final handler = await service('browser.desktop').handlerFor(web);
      expect(handler!.name, 'Mine');
      expect(handler.icon, isNull);
    });

    test('an SVG-only icon keeps the name and drops the icon', () async {
      write(
        'usr/share/applications/b.desktop',
        '[Desktop Entry]\nName=B\nIcon=b\n',
      );
      write('usr/share/icons/hicolor/scalable/apps/b.svg', '<svg/>');
      final handler = await service('b.desktop').handlerFor(web);
      expect(handler!.name, 'B');
      expect(handler.icon, isNull);
    });

    test('pixmaps and absolute icon paths', () async {
      write(
        'usr/share/applications/p.desktop',
        '[Desktop Entry]\nName=P\nIcon=p\n',
      );
      write('usr/share/pixmaps/p.png', 'png');
      expect(
        path.normalize(
          ((await service('p.desktop').handlerFor(web))!.icon! as FileImage)
              .file
              .absolute
              .path,
        ),
        path.join(root.path, 'usr', 'share', 'pixmaps', 'p.png'),
      );

      write(
        'usr/share/applications/a.desktop',
        '[Desktop Entry]\nName=A\nIcon=${root.path}/opt/a/icon.png\n',
      );
      write('opt/a/icon.png', 'png');
      expect(
        ((await service('a.desktop').handlerFor(web))!.icon! as FileImage)
            .file
            .path,
        '${root.path}/opt/a/icon.png',
      );
    });

    test('no default, or an entry that is not installed, is null', () async {
      expect(await service('', exitCode: 1).handlerFor(web), isNull);
      expect(await service('\n').handlerFor(web), isNull);
      expect(await service('gone.desktop').handlerFor(web), isNull);
    });
  });

  test('a nested desktop file ID is found under its subdirectory', () {
    expect(LinuxLinkHandlerService.desktopEntryPaths('firefox.desktop'), [
      'firefox.desktop',
    ]);
    expect(LinuxLinkHandlerService.desktopEntryPaths('kde4-kmail.desktop'), [
      'kde4-kmail.desktop',
      'kde4/kmail.desktop',
    ]);
  });

  test('the cache keeps at most maxEntries lookups', () async {
    final service = _CountingService();
    for (var i = 0; i <= CachingLinkHandlerService.maxEntries; i++) {
      await service.handlerFor(ClipLink.detect('https://host$i.com')!);
    }
    expect(service.calls, CachingLinkHandlerService.maxEntries + 1);
    // The most recent are still cached; the first was evicted.
    await service.handlerFor(
      ClipLink.detect(
        'https://host${CachingLinkHandlerService.maxEntries}.com',
      )!,
    );
    expect(service.calls, CachingLinkHandlerService.maxEntries + 1);
    expect(
      service.cachedHandlerFor(ClipLink.detect('https://host0.com')!),
      isNull,
    );
    await service.handlerFor(ClipLink.detect('https://host0.com')!);
    expect(service.calls, CachingLinkHandlerService.maxEntries + 2);
  });

  test('desktop entry names follow the locale', () {
    final keys = parseDesktopEntry('''
[Desktop Entry]
Name=Text Editor
Name[fr]=Éditeur de texte
Name[pt_BR]=Editor de texto
''');
    expect(
      localizedEntryValue(keys, 'Name', {'LANG': 'fr_FR.UTF-8'}),
      'Éditeur de texte',
    );
    expect(
      localizedEntryValue(keys, 'Name', {'LANG': 'pt_BR.UTF-8'}),
      'Editor de texto',
    );
    expect(
      localizedEntryValue(keys, 'Name', {'LANG': 'de_DE.UTF-8'}),
      'Text Editor',
    );
    expect(localizedEntryValue(keys, 'Name', {'LANG': 'C'}), 'Text Editor');
    expect(
      localizedEntryValue(keys, 'Name', {'LC_ALL': 'fr_CA', 'LANG': 'en_US'}),
      'Éditeur de texte',
    );
    expect(localizedEntryValue(keys, 'Name', {}), 'Text Editor');
  });

  test('xdgDataDirs follows the spec', () {
    expect(xdgDataDirs({'HOME': '/home/u'}), [
      path.join('/home/u', '.local', 'share'),
      '/usr/local/share',
      '/usr/share',
    ]);
    expect(
      xdgDataDirs({
        'HOME': '/home/u',
        'XDG_DATA_HOME': '/data',
        'XDG_DATA_DIRS': '/a:relative:/b',
      }),
      ['/data', '/a', '/b'],
    );
    expect(
      xdgDataDirs({'HOME': '/home/u', 'XDG_DATA_HOME': 'relative'}).first,
      path.join('/home/u', '.local', 'share'),
    );
  });

  test('a failed lookup is the generic glyph, not a cached throw', () async {
    final service = _ThrowingService();
    final link = ClipLink.detect('https://example.com')!;
    expect(await service.handlerFor(link), isNull);
    expect(await service.handlerFor(link), isNull);
    expect(service.calls, 1);
  });

  test('the cache key holds what each platform routes by', () {
    String key(CachingLinkHandlerService service, String url) =>
        service.cacheKeyFor(ClipLink.detect(url)!.openUri(service.platform));
    final windows = WindowsLinkHandlerService();
    final linux = LinuxLinkHandlerService();
    final macos = ChannelLinkHandlerService(platform: 'macos');
    final android = ChannelLinkHandlerService(platform: 'android');

    // Windows and Linux: the scheme decides, whatever the kind of link.
    for (final service in [windows, linux]) {
      expect(key(service, 'https://a.com/x'), key(service, 'https://b.org/y'));
      expect(
        key(service, 'https://a.com/x'),
        key(service, 'https://www.google.com/maps/place/x'),
      );
    }
    // macOS: the whole URL, which universal links can match on.
    expect(key(macos, 'https://a.com/x'), isNot(key(macos, 'https://b.org/x')));
    expect(key(macos, 'https://a.com/x'), isNot(key(macos, 'https://a.com/y')));
    expect(
      key(macos, 'https://a.com/x?app=1'),
      isNot(key(macos, 'https://a.com/x?app=0')),
    );
    // Android: per host and path - Docs and Sheets apart, Google Maps apart
    // from Google search, and routes that differ deeper down apart too. The
    // query is not part of it.
    expect(
      key(android, 'https://docs.google.com/document/d/1'),
      isNot(key(android, 'https://docs.google.com/spreadsheets/d/1')),
    );
    expect(
      key(android, 'https://example.com/open/native'),
      isNot(key(android, 'https://example.com/open/web')),
    );
    expect(
      key(android, 'https://example.com/a?x=1'),
      key(android, 'https://example.com/a?x=2'),
    );
    expect(
      key(android, 'https://www.google.com/maps/place/x'),
      isNot(key(android, 'https://www.google.com/search?q=x')),
    );
    // A geo: or tel: path is the place or number itself.
    expect(key(android, 'geo:1.0,2.0'), key(android, 'geo:3.0,4.0'));
  });
}

class _MutableHandlerService extends CachingLinkHandlerService {
  _MutableHandlerService() : super(platform: 'windows');

  LinkHandler handler = const LinkHandler(name: 'Browser');

  @override
  String cacheKeyFor(Uri uri) => uri.scheme;

  @override
  Future<LinkHandler?> lookUp(Uri uri) async => handler;
}

class _ThrowingService extends CachingLinkHandlerService {
  _ThrowingService() : super(platform: 'windows');

  int calls = 0;

  @override
  String cacheKeyFor(Uri uri) => uri.scheme;

  @override
  Future<LinkHandler?> lookUp(Uri uri) async {
    calls++;
    throw const FileSystemException('icon gone');
  }
}

class _CountingService extends CachingLinkHandlerService {
  _CountingService() : super(platform: 'macos');

  int calls = 0;

  @override
  String cacheKeyFor(Uri uri) => uri.host;

  @override
  Future<LinkHandler?> lookUp(Uri uri) async {
    calls++;
    return LinkHandler(name: uri.host);
  }
}
