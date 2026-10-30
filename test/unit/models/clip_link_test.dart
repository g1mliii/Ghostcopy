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

  group('more kinds', () {
    test('street addresses open as a maps search', () {
      for (final (text, label) in [
        ('123 Main St', '123 Main St'),
        (
          '1600 Amphitheatre Pkwy, Mountain View, CA 94043',
          '1600 Amphitheatre Pkwy, Mountain View, CA 94043',
        ),
        ('290 Bremner Blvd\nToronto, ON M5V 3L9', '290 Bremner Blvd'),
        ('221B Baker Street\nLondon NW1 6XE', '221B Baker Street'),
        (
          '350 rue Sherbrooke Ouest, Montréal',
          '350 rue Sherbrooke Ouest, Montréal',
        ),
        ('Friedrichstraße 43', 'Friedrichstraße 43'),
        ('Hauptstraße 5, 10115 Berlin', 'Hauptstraße 5, 10115 Berlin'),
        ('Unit 4, 55 Queen St E', 'Unit 4, 55 Queen St E'),
        ('10 Downing Street', '10 Downing Street'),
      ]) {
        final link = ClipLink.detect(text);
        expect(link?.kind, ClipLinkKind.map, reason: text);
        expect(link!.label, label, reason: text);
        expect(link.uri.scheme, 'geo');
      }
      final multi = ClipLink.detect('290 Bremner Blvd\nToronto, ON M5V 3L9')!;
      expect(
        multi.openUri('android').toString(),
        'geo:0,0?q=290+Bremner+Blvd%2C+Toronto%2C+ON+M5V+3L9',
      );
      expect(
        multi.openUri('windows').queryParameters['query'],
        '290 Bremner Blvd, Toronto, ON M5V 3L9',
      );
      expect(
        multi.openUri('ios').queryParameters['q'],
        '290 Bremner Blvd, Toronto, ON M5V 3L9',
      );
    });

    test('things that are not addresses stay text', () {
      for (final text in [
        'meet me at 5',
        '5 people went to the big party on Main St last night',
        'Shopping list\nmilk\neggs',
        'line 1\nline 2\nline 3\nline 4\nline 5',
        'Dear Sam,\nThanks for the 3 boxes.\nBest',
        'email me at a@b.co, 12 Main St',
      ]) {
        expect(
          ClipLink.detect(text)?.kind,
          isNot(ClipLinkKind.map),
          reason: text,
        );
      }
    });

    test('coordinates, decimal and degrees', () {
      final decimal = ClipLink.detect('43.64263, -79.38712')!;
      expect(decimal.kind, ClipLinkKind.map);
      expect(decimal.uri.toString(), 'geo:43.64263,-79.38712');
      expect(decimal.openUri('android').toString(), 'geo:43.64263,-79.38712');

      final dms = ClipLink.detect('43°38\'33.5"N 79°23\'13.6"W')!;
      expect(dms.kind, ClipLinkKind.map);
      expect(dms.uri.toString(), 'geo:43.642639,-79.387111');

      // Two ordinary numbers, or out of range.
      expect(ClipLink.detect('1.5, 2.5'), isNull);
      expect(ClipLink.detect('95.12345, 10.12345'), isNull);
    });

    test('phone numbers can be texted too', () {
      final phone = ClipLink.detect('+1 416 555 0199')!;
      expect(phone.alternate!.label, 'Text');
      expect(phone.alternate!.uri.toString(), 'sms:+14165550199');
      expect(phone.canAlternateOn('macos'), isTrue);
      expect(phone.canAlternateOn('linux'), isFalse);
      expect(ClipLink.detect('https://example.com')!.alternate, isNull);
    });

    test('meeting links', () {
      for (final (url, service) in [
        ('https://us02web.zoom.us/j/81234567890?pwd=abc', 'Zoom'),
        ('https://zoom.us/j/81234567890', 'Zoom'),
        ('https://meet.google.com/abc-defg-hij', 'Google Meet'),
        (
          'https://teams.microsoft.com/l/meetup-join/19%3ameeting_abc/0',
          'Microsoft Teams',
        ),
        ('https://teams.live.com/meet/9876543210', 'Microsoft Teams'),
        ('https://acme.webex.com/meet/jdoe', 'Webex'),
        ('https://facetime.apple.com/join#v=1&p=abc', 'FaceTime'),
        ('zoommtg://zoom.us/join?confno=81234567890', 'Zoom'),
        ('msteams:/l/meetup-join/19%3ameeting_abc', 'Microsoft Teams'),
      ]) {
        final link = ClipLink.detect(url);
        expect(link?.kind, ClipLinkKind.meeting, reason: url);
        expect(link!.service, service, reason: url);
        expect(link.actionLabel, 'Join meeting');
      }
      // A Zoom page that is not a meeting.
      expect(
        ClipLink.detect('https://zoom.us/pricing')!.kind,
        ClipLinkKind.web,
      );
      expect(
        ClipLink.detect('https://meet.google.com/')!.kind,
        ClipLinkKind.web,
      );
    });

    test('music links, with a way to find them elsewhere', () {
      for (final (url, service) in [
        ('https://open.spotify.com/track/4uLU6hMCjMI75M1A2tKUQC', 'Spotify'),
        ('https://music.apple.com/ca/album/x/123?i=456', 'Apple Music'),
        ('https://music.youtube.com/watch?v=abc', 'YouTube Music'),
        ('https://soundcloud.com/artist/track', 'SoundCloud'),
        ('https://tidal.com/browse/track/123', 'TIDAL'),
        ('https://www.deezer.com/track/123', 'Deezer'),
        ('https://music.amazon.ca/albums/B0', 'Amazon Music'),
        ('https://artist.bandcamp.com/album/x', 'Bandcamp'),
        ('https://podcasts.apple.com/us/podcast/x/id1', 'Apple Podcasts'),
      ]) {
        final link = ClipLink.detect(url);
        expect(link?.kind, ClipLinkKind.music, reason: url);
        expect(link!.service, service, reason: url);
        expect(link.actionLabel, 'Open in $service');
        expect(
          link.alternate!.uri.toString(),
          'https://song.link/$url',
          reason: url,
        );
      }

      final uri = ClipLink.detect('spotify:track:4uLU6hMCjMI75M1A2tKUQC')!;
      expect(uri.kind, ClipLinkKind.music);
      expect(
        uri.uri.toString(),
        'https://open.spotify.com/track/4uLU6hMCjMI75M1A2tKUQC',
      );
    });

    test('video links', () {
      for (final (url, service) in [
        ('https://www.youtube.com/watch?v=dQw4w9WgXcQ', 'YouTube'),
        ('https://youtu.be/dQw4w9WgXcQ', 'YouTube'),
        ('https://vimeo.com/123456', 'Vimeo'),
        ('https://www.twitch.tv/somebody', 'Twitch'),
        ('https://www.tiktok.com/@user/video/1', 'TikTok'),
      ]) {
        final link = ClipLink.detect(url);
        expect(link?.kind, ClipLinkKind.video, reason: url);
        expect(link!.actionLabel, 'Watch on $service');
      }
    });

    test('tracking numbers, checked against their check digit', () {
      final ups = ClipLink.detect('1Z879E930346834440')!;
      expect(ups.kind, ClipLinkKind.tracking);
      expect(ups.service, 'UPS');
      expect(ups.uri.queryParameters['tracknum'], '1Z879E930346834440');
      expect(ups.actionLabel, 'Track package');
      expect(ClipLink.detect('1z879e930346834440')!.service, 'UPS');

      final usps = ClipLink.detect('9400111899223197428490')!;
      expect(usps.service, 'USPS');

      expect(ClipLink.detect('RR123456785CA')!.service, 'Canada Post');
      expect(ClipLink.detect('LM473124829US')!.service, 'USPS');
      expect(ClipLink.detect('RA123456785GB')!.service, 'Royal Mail');
      expect(ClipLink.detect('RA123456785AU')!.service, 'Australia Post');
      expect(ClipLink.detect('RA123456785DE')!.service, 'Post');

      // Wrong check digit, or the right shape for nothing in particular.
      expect(ClipLink.detect('1Z879E930346834441'), isNull);
      expect(ClipLink.detect('RA123456780DE'), isNull);
      expect(ClipLink.detect('123456789012'), isNull);
    });

    test('links into apps, and only known ones', () {
      final obsidian = ClipLink.detect(
        'obsidian://open?vault=Notes&file=Inbox',
      )!;
      expect(obsidian.kind, ClipLinkKind.app);
      expect(obsidian.service, 'Obsidian');
      expect(obsidian.actionLabel, 'Open in Obsidian');
      expect(
        ClipLink.detect('slack://channel?team=T1&id=C1')!.service,
        'Slack',
      );
      expect(
        ClipLink.detect('vscode://file/home/u/a.dart')!.service,
        'VS Code',
      );

      for (final text in [
        'javascript:alert(1)',
        'file:///etc/passwd',
        'intent://scan/#Intent;scheme=zxing;end',
        'ms-msdt:/id PCWDiagnostic',
        'search-ms:query=x',
        'obsidian:',
        'notascheme://x',
      ]) {
        expect(ClipLink.detect(text), isNull, reason: text);
      }
    });

    test('local and dev addresses open in the browser', () {
      for (final (text, url) in [
        ('localhost:3000', 'http://localhost:3000'),
        ('192.168.1.1', 'http://192.168.1.1'),
        ('10.0.0.5:8080/admin', 'http://10.0.0.5:8080/admin'),
        ('printer.local', 'http://printer.local'),
        ('nas.lan:5000', 'http://nas.lan:5000'),
        ('example.com:8443', 'http://example.com:8443'),
      ]) {
        final link = ClipLink.detect(text);
        expect(link?.kind, ClipLinkKind.web, reason: text);
        expect(link!.uri.toString(), url);
      }
      expect(ClipLink.detect('999.1.1.1'), isNull);
      expect(ClipLink.detect('1.2.3.4.5'), isNull);
    });
  });
}
