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

  test(
    'legacy Windows icon masks retain transparent pixels and row padding',
    () {
      final pixels = Uint8List(9 * 2 * 4);
      final mask = Uint8List.fromList([0x80, 0x80, 0, 0, 0x40, 0, 0, 0]);
      expect(
        restoreWindowsIconAlpha(pixels, width: 9, height: 2, andMask: mask),
        isTrue,
      );
      final transparent = [
        for (var i = 0; i < 18; i++)
          if (pixels[i * 4 + 3] == 0) i,
      ];
      expect(transparent, [0, 8, 10]);
      expect(pixels[4 + 3], 255);
    },
  );

  test('Windows alpha icons keep their existing transparency', () {
    final pixels = Uint8List.fromList([10, 20, 30, 128, 0, 0, 0, 0]);
    expect(
      restoreWindowsIconAlpha(
        pixels,
        width: 2,
        height: 1,
        andMask: Uint8List.fromList([255, 0, 0, 0]),
      ),
      isTrue,
    );
    expect(pixels, [10, 20, 30, 128, 0, 0, 0, 0]);
    expect(restoreWindowsIconAlpha(Uint8List(4), width: 1, height: 1), isFalse);
  });

  test(
    'Linux uses the native desktop theme icon rather than hicolor artwork',
    () async {
      const channel = MethodChannel('com.ghostcopy/link_handler');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            ..setMockMethodCallHandler(channel, (call) async {
              expect(call.method, 'handlerFor');
              expect(call.arguments, {'url': 'https:'});
              return {
                'name': 'Themed browser',
                'icon': Uint8List.fromList([1, 2, 3]),
              };
            });
      addTearDown(() {
        messenger.setMockMethodCallHandler(channel, null);
      });
      final handler = await LinuxLinkHandlerService().lookUp(
        Uri.parse('https://example.com'),
      );
      expect(handler!.name, 'Themed browser');
      expect((handler.icon! as MemoryImage).bytes, [1, 2, 3]);
    },
  );

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
        expect(asked, hasLength(2));
        expect(service.cachedHandlerFor(second)!.name, 'Google Maps');
        await service.handlerFor(second);
        expect(asked, hasLength(2));
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

    test('Android query and fragment routes keep their own handlers', () async {
      answer = (url) => {
        'name': url.endsWith('#native') || url.endsWith('?app=1')
            ? 'Native'
            : 'Browser',
      };
      final service = ChannelLinkHandlerService(
        platform: 'android',
        channel: channel,
      );
      final browser = ClipLink.detect('https://example.com/open?app=0')!;
      final native = ClipLink.detect('https://example.com/open?app=1')!;
      final fragment = ClipLink.detect(
        'https://example.com/open?app=0#native',
      )!;
      expect((await service.handlerFor(browser))!.name, 'Browser');
      expect((await service.handlerFor(native))!.name, 'Native');
      expect((await service.handlerFor(fragment))!.name, 'Native');
      expect((await service.handlerFor(browser))!.name, 'Browser');
      expect(asked, hasLength(3));
    });

    test('Android opaque URI routes keep distinct cached handlers', () async {
      answer = (url) => {'name': url};
      final service = ChannelLinkHandlerService(
        platform: 'android',
        channel: channel,
      );
      for (final text in [
        'mailto:alice@example.com',
        'mailto:bob@other.com',
        'tel:+14165550199',
        'tel:+442079460123',
        'geo:1,2',
        'geo:3,4',
      ]) {
        final link = ClipLink.detect(text)!;
        final expected = link.openUri('android').toString();
        expect((await service.handlerFor(link))!.name, expected);
        expect((await service.handlerFor(link))!.name, expected);
      }
      expect(asked, hasLength(6));
    });

    test('Android ports keep their own handlers', () async {
      answer = (url) => {
        'name': Uri.parse(url).port == 8443 ? 'Native' : 'Browser',
      };
      final service = ChannelLinkHandlerService(
        platform: 'android',
        channel: channel,
      );
      final browser = ClipLink.detect('https://example.com/open')!;
      final native = ClipLink.detect('https://example.com:8443/open')!;
      expect((await service.handlerFor(browser))!.name, 'Browser');
      expect((await service.handlerFor(native))!.name, 'Native');
      expect((await service.handlerFor(browser))!.name, 'Browser');
      expect(asked, hasLength(2));
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

    File write(String relative, List<int> bytes) {
      final file = File(path.join(root.path, relative))
        ..createSync(recursive: true)
        ..writeAsBytesSync(bytes);
      return file;
    }

    LinuxLinkHandlerService service({
      List<String> names = const ['browser'],
      String? iconPath,
    }) => LinuxLinkHandlerService(
      lookup: (scheme) async {
        expect(scheme, 'https');
        return (
          name: 'GIO browser',
          png: await readLinuxLinkIcon(
            names: names,
            iconPath: iconPath,
            environment: env,
          ),
        );
      },
    );

    final web = ClipLink.detect('https://example.com')!;

    test('uses the resolved app name and nearest hicolor icon', () async {
      write('usr/share/icons/hicolor/128x128/apps/browser.png', [128]);
      write('usr/share/icons/hicolor/64x64/apps/browser.png', [64]);
      final handler = await service().handlerFor(web);
      expect(handler!.name, 'GIO browser');
      expect((handler.icon! as MemoryImage).bytes, [64]);
    });

    test('user icons take priority over system icons', () async {
      write('usr/share/icons/hicolor/64x64/apps/browser.png', [1]);
      write('home/share/icons/hicolor/64x64/apps/browser.png', [2]);
      final handler = await service().handlerFor(web);
      expect((handler!.icon! as MemoryImage).bytes, [2]);
    });

    test('legacy user icons take priority over XDG icons', () async {
      write('home/share/icons/hicolor/64x64/apps/browser.png', [1]);
      write('home/.icons/hicolor/64x64/apps/browser.png', [2]);
      final handler = await service().handlerFor(web);
      expect((handler!.icon! as MemoryImage).bytes, [2]);
    });

    test('tries themed fallbacks, pixmaps and local file icons', () async {
      write('usr/share/pixmaps/fallback.png', [3]);
      final handler = await service(
        names: ['missing', 'fallback'],
      ).handlerFor(web);
      expect((handler!.icon! as MemoryImage).bytes, [3]);
      final file = write('opt/browser.png', [4]);
      final local = await service(iconPath: file.path).handlerFor(web);
      expect((local!.icon! as MemoryImage).bytes, [4]);
    });

    test('missing or SVG-only artwork retains the app name', () async {
      write('usr/share/icons/hicolor/scalable/apps/browser.svg', [1]);
      final handler = await service().handlerFor(web);
      expect(handler!.name, 'GIO browser');
      expect(handler.icon, isNull);
    });

    test('refresh loads an icon replaced at the same path', () async {
      var now = DateTime(2026);
      await withClock(Clock(() => now), () async {
        final file = write('opt/browser.png', [1, 2, 3]);
        final instance = service(iconPath: file.path);
        final original = await instance.handlerFor(web);
        file.writeAsBytesSync([4, 5, 6]);
        now = now.add(
          CachingLinkHandlerService.maxAge + const Duration(seconds: 1),
        );
        final refreshed = await instance.handlerFor(web);
        expect((refreshed!.icon! as MemoryImage).bytes, [4, 5, 6]);
        expect(refreshed, isNot(same(original)));
        expect(instance.cachedHandlerFor(web), same(refreshed));
      });
    });

    test('oversized artwork falls back without losing the app', () async {
      final file = write('opt/huge.png', List.filled(1024 * 1024 + 1, 0));
      final handler = await service(iconPath: file.path).handlerFor(web);
      expect(handler!.name, 'GIO browser');
      expect(handler.icon, isNull);
    });

    test('no association gives the generic glyph', () async {
      final instance = LinuxLinkHandlerService(lookup: (_) async => null);
      expect(await instance.handlerFor(web), isNull);
    });

    test('native GIO lookup handles an unregistered scheme', () async {
      expect(
        await LinuxLinkHandlerService().lookUp(
          Uri.parse('ghostcopy-test-unregistered://item'),
        ),
        isNull,
      );
    }, skip: !Platform.isLinux);
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

    // GIO chooses a default per scheme; Windows resolves full web URLs.
    expect(key(linux, 'https://a.com/x'), key(linux, 'https://b.org/y'));
    expect(
      key(windows, 'https://a.com/x'),
      isNot(key(windows, 'https://b.org/y')),
    );
    expect(
      key(windows, 'https://a.com/x?app=1'),
      isNot(key(windows, 'https://a.com/x?app=0')),
    );
    // macOS: the whole URL, which universal links can match on.
    expect(key(macos, 'https://a.com/x'), isNot(key(macos, 'https://b.org/x')));
    expect(key(macos, 'https://a.com/x'), isNot(key(macos, 'https://a.com/y')));
    expect(
      key(macos, 'https://a.com/x?app=1'),
      isNot(key(macos, 'https://a.com/x?app=0')),
    );
    // Android Dynamic App Links can also route by query and fragment.
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
      isNot(key(android, 'https://example.com/a?x=2')),
    );
    expect(
      key(android, 'https://www.google.com/maps/place/x'),
      isNot(key(android, 'https://www.google.com/search?q=x')),
    );
    // Android filters can match the opaque scheme-specific part too.
    expect(key(android, 'geo:1.0,2.0'), isNot(key(android, 'geo:3.0,4.0')));
  });

  test('native Windows lookup resolves a complete web URL', () async {
    final handler = await WindowsLinkHandlerService().lookUp(
      Uri.parse('https://example.com/open?app=1#details'),
    );
    expect(handler, isNotNull);
    expect(handler!.name, isNotEmpty);
  }, skip: !Platform.isWindows);
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
