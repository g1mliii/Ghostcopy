import 'package:flutter_test/flutter_test.dart';
import 'package:ghostcopy/models/clip_link.dart';

void main() {
  group('ClipLink.detect', () {
    test('web links, with the host as the label', () {
      final link = ClipLink.detect('https://www.example.com/a/b?c=d')!;
      expect(link.kind, ClipLinkKind.web);
      expect(link.label, 'example.com');
      expect(link.uri.toString(), 'https://www.example.com/a/b?c=d');

      final bare = ClipLink.detect('  www.example.com/page  ')!;
      expect(bare.kind, ClipLinkKind.web);
      expect(bare.uri.toString(), 'https://www.example.com/page');

      expect(ClipLink.detect('http://localhost:8080')!.kind, ClipLinkKind.web);
    });

    test('Apple Maps links, classic and current forms', () {
      final classic = ClipLink.detect(
        'https://maps.apple.com/?q=Eiffel%20Tower&ll=48.8584,2.2945',
      )!;
      expect(classic.kind, ClipLinkKind.map);
      expect(classic.label, 'Eiffel Tower');

      final place = ClipLink.detect(
        'https://maps.apple.com/place?address=1%20Infinite%20Loop&coordinate=37.33,-122.03&name=Apple',
      )!;
      expect(place.kind, ClipLinkKind.map);
      expect(place.label, 'Apple');

      final short = ClipLink.detect('https://maps.apple/p/abc123')!;
      expect(short.kind, ClipLinkKind.map);
      expect(short.label, 'Apple Maps');
    });

    test('Google Maps links', () {
      final place = ClipLink.detect(
        'https://www.google.com/maps/place/CN+Tower/@43.6426,-79.3871,17z/data=!3m1',
      )!;
      expect(place.kind, ClipLinkKind.map);
      expect(place.label, 'CN Tower');

      final search = ClipLink.detect(
        'https://www.google.com/maps/search/?api=1&query=Union+Station',
      )!;
      expect(search.kind, ClipLinkKind.map);
      expect(search.label, 'Union Station');

      final short = ClipLink.detect('https://maps.app.goo.gl/xyz')!;
      expect(short.kind, ClipLinkKind.map);
      expect(short.label, 'Google Maps');

      // Google, but not Maps.
      expect(
        ClipLink.detect('https://www.google.com/search?q=ghostcopy')!.kind,
        ClipLinkKind.web,
      );
      expect(ClipLink.detect('https://goo.gl/abc')!.kind, ClipLinkKind.web);
    });

    test('geo: URIs', () {
      final coords = ClipLink.detect('geo:43.6426,-79.3871')!;
      expect(coords.kind, ClipLinkKind.map);
      expect(coords.label, '43.6426,-79.3871');

      final query = ClipLink.detect('geo:0,0?q=CN%20Tower')!;
      expect(query.label, 'CN Tower');

      expect(ClipLink.detect('geo:0,0'), isNull);
    });

    test('email addresses and mailto: links', () {
      final bare = ClipLink.detect('someone@example.co.uk')!;
      expect(bare.kind, ClipLinkKind.email);
      expect(bare.uri.toString(), 'mailto:someone@example.co.uk');

      final mailto = ClipLink.detect('mailto:a.b+c@example.com?subject=Hi')!;
      expect(mailto.kind, ClipLinkKind.email);
      expect(mailto.label, 'a.b+c@example.com');
      expect(mailto.uri.queryParameters['subject'], 'Hi');

      expect(ClipLink.detect('not@an'), isNull);
    });

    test('phone numbers as people write them', () {
      for (final number in [
        '+1 416 555 0199',
        '(416) 555-0199',
        '416-555-0199',
        '416.555.0199',
        '+447911123456',
        '1-800-555-0199',
      ]) {
        final link = ClipLink.detect(number);
        expect(link?.kind, ClipLinkKind.phone, reason: number);
        expect(link!.label, number);
      }
      expect(
        ClipLink.detect('+1 (416) 555-0199')!.uri.toString(),
        'tel:+14165550199',
      );
      expect(
        ClipLink.detect('tel:4165550199')!.uri.toString(),
        'tel:4165550199',
      );
      expect(ClipLink.detect('0800-123456')!.kind, ClipLinkKind.phone);
      expect(ClipLink.detect('555-1234')!.kind, ClipLinkKind.phone);
      expect(
        ClipLink.detect('tel:%2B14165550199')!.uri.toString(),
        'tel:+14165550199',
      );
    });

    test('things that only look like phone numbers stay text', () {
      for (final text in [
        '4165550199', // bare digits: codes, order and account numbers
        '123456',
        '2026-10-30',
        '30/10/2026',
        '192.168.1.10',
        '1.2.3',
        '4111 1111 1111 1111', // a card number has too many digits
        '+12', // too few
        '978-0-306-40615-7', // an ISBN
        '1000-2000', // a range
        'tel:%', // a stray escape must not throw while a row builds
        'tel:%zz',
      ]) {
        expect(ClipLink.detect(text), isNull, reason: text);
      }
    });

    test('anything that is not one link stays text', () {
      for (final text in [
        '',
        '   ',
        'hello world',
        'see https://example.com for details',
        'https://example.com\nhttps://example.org',
        'notes.md',
        'ftp://example.com/file',
        'http://nodot',
        'javascript:alert(1)',
        'https://${'a' * ClipLink.maxLength}.com',
      ]) {
        expect(ClipLink.detect(text), isNull, reason: text);
      }
    });
  });

  group('ClipLink.openUri', () {
    final appleClassic = ClipLink.detect(
      'https://maps.apple.com/?q=Eiffel%20Tower&ll=48.8584,2.2945',
    )!;
    final applePlace = ClipLink.detect(
      'https://maps.apple.com/place?name=Apple&coordinate=37.33,-122.03',
    )!;
    final appleShort = ClipLink.detect('https://maps.apple/p/abc123')!;
    final google = ClipLink.detect(
      'https://www.google.com/maps/place/CN+Tower/@43.6426,-79.3871,17z',
    )!;
    final geo = ClipLink.detect('geo:43.6426,-79.3871?q=CN%20Tower')!;

    test('Android opens Apple Maps and geo: links as geo:', () {
      expect(
        appleClassic.openUri('android').toString(),
        'geo:48.8584,2.2945?q=Eiffel+Tower',
      );
      expect(
        applePlace.openUri('android').toString(),
        'geo:37.33,-122.03?q=Apple',
      );
      expect(
        geo.openUri('android').toString(),
        'geo:43.6426,-79.3871?q=CN+Tower',
      );
      // Google Maps' own app claims these, and a short link has nothing to
      // rewrite.
      expect(google.openUri('android'), google.uri);
      expect(appleShort.openUri('android'), appleShort.uri);
    });

    test('macOS sends classic Apple Maps links to the Maps app', () {
      expect(
        appleClassic.openUri('macos').toString(),
        'maps://?q=Eiffel%20Tower&ll=48.8584,2.2945',
      );
      // The /place form has ids maps: cannot carry.
      expect(applePlace.openUri('macos'), applePlace.uri);
      expect(
        geo.openUri('macos').toString(),
        'maps://?q=CN+Tower&ll=43.6426%2C-79.3871',
      );
      expect(google.openUri('macos'), google.uri);
    });

    test('iOS opens Apple Maps links as sent, and geo: as Apple Maps', () {
      expect(appleClassic.openUri('ios'), appleClassic.uri);
      expect(
        geo.openUri('ios').toString(),
        'https://maps.apple.com/?q=CN+Tower&ll=43.6426%2C-79.3871',
      );
    });

    test('Windows and Linux open geo: as a Google Maps search', () {
      for (final platform in ['windows', 'linux']) {
        expect(
          geo.openUri(platform).toString(),
          'https://www.google.com/maps/search/?api=1&query=CN+Tower',
        );
        expect(appleClassic.openUri(platform), appleClassic.uri);
      }
      final coordsOnly = ClipLink.detect('geo:43.6426,-79.3871')!;
      expect(
        coordsOnly.openUri('windows').queryParameters['query'],
        '43.6426,-79.3871',
      );
    });

    test('web, email and phone links open as sent everywhere', () {
      final links = [
        ClipLink.detect('https://example.com')!,
        ClipLink.detect('a@example.com')!,
        ClipLink.detect('+1 416 555 0199')!,
      ];
      for (final link in links) {
        for (final platform in ['android', 'ios', 'macos', 'windows']) {
          expect(link.openUri(platform), link.uri);
        }
      }
    });
  });

  test('Linux has no handler for phone numbers', () {
    final phone = ClipLink.detect('+1 416 555 0199')!;
    expect(phone.canOpenOn('linux'), isFalse);
    expect(phone.canOpenOn('windows'), isTrue);
    expect(ClipLink.detect('https://example.com')!.canOpenOn('linux'), isTrue);
  });
}
