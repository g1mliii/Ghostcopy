import 'package:flutter_test/flutter_test.dart';
import 'package:ghostcopy/models/clip_link.dart';

void main() {
  test(
    'email dot-atoms accept standard punctuation and encode mailto paths',
    () {
      const punctuation = r'''!#$%&'*+-/=?^_`{|}~''';
      for (final character in punctuation.split('')) {
        final address = 'a${character}b@example.com';
        final bare = ClipLink.detect(address)!;
        expect(bare.kind, ClipLinkKind.email, reason: address);
        expect(bare.label, address);
        expect(bare.uri.hasQuery, isFalse);
        expect(bare.uri.hasFragment, isFalse);
        expect(ClipLink.detect(bare.uri.toString())?.label, address);
      }
      expect(
        ClipLink.detect('mailto:o%27connor@example.com')?.label,
        '''o'connor@example.com''',
      );
      for (final address in [
        '.person@example.com',
        'person.@example.com',
        'first..last@example.com',
      ]) {
        expect(ClipLink.detect(address), isNull, reason: address);
      }
    },
  );

  test('map recognition uses Google-owned domains only', () {
    for (final domain in [
      'google.com',
      'google.ca',
      'google.co.uk',
      'google.com.au',
      'google.cat',
    ]) {
      expect(
        ClipLink.detect('https://maps.$domain/maps/search/Bank')?.kind,
        ClipLinkKind.map,
        reason: domain,
      );
    }
    for (final domain in [
      'google.com.de',
      'google.co.de',
      'google.zz',
      'google.com.attacker.com',
    ]) {
      expect(
        ClipLink.detect('https://maps.$domain/maps/search/Bank')?.kind,
        ClipLinkKind.web,
        reason: domain,
      );
    }
  });

  test('Apple problem reports retain their workflow on Android', () {
    const url =
        'https://maps.apple.com/report-a-problem?coordinate=37.316115,-122.050910';
    final link = ClipLink.detect(url)!;
    expect(link.openUri('android').toString(), url);
  });

  test('bare mail recipients encode mailto reserved characters', () {
    for (final (address, target) in [
      ('Mike&family@example.org', 'mailto:Mike%26family@example.org'),
      ('a/b@example.org', 'mailto:a%2Fb@example.org'),
      ('a?b@example.org', 'mailto:a%3Fb@example.org'),
      ('a#b@example.org', 'mailto:a%23b@example.org'),
    ]) {
      final link = ClipLink.detect(address)!;
      expect(link.uri.toString(), target);
      expect(ClipLink.detect(target)?.label, address);
    }
  });

  test('geo coordinates require a recognized reference system', () {
    for (final crs in ['local', '', 'epsg4326']) {
      expect(ClipLink.detect('geo:48.2,16.3;crs=$crs'), isNull);
      expect(ClipLink.detect('geo:0,0;crs=$crs?q=Bank'), isNull);
    }
    for (final crs in ['wgs84', 'WGS84']) {
      final link = ClipLink.detect('geo:48.2,16.3;CRS=$crs')!;
      expect(link.openUri('ios').host, 'maps.apple.com');
    }
  });

  test('YouTube video actions require a playable target', () {
    for (final path in [
      'results?search_query=beatles',
      'feed/subscriptions',
      'channel/UCabc',
      'watch',
      'watch?v=',
      'shorts/',
      'embed/',
      'live/',
    ]) {
      expect(
        ClipLink.detect('https://www.youtube.com/$path')?.kind,
        ClipLinkKind.web,
        reason: path,
      );
    }
    for (final path in ['watch?v=abc', 'shorts/abc', 'embed/abc', 'live/abc']) {
      expect(
        ClipLink.detect('https://www.youtube.com/$path')?.kind,
        ClipLinkKind.video,
        reason: path,
      );
    }
    expect(ClipLink.detect('https://youtu.be/abc')?.kind, ClipLinkKind.video);
    expect(ClipLink.detect('https://youtu.be/')?.kind, ClipLinkKind.web);
  });

  test('Apple options and place identities survive Android opens', () {
    for (final url in [
      'https://maps.apple.com/frame?center=40.753035,-73.981846&map=satellite&span=0.05,0.05',
      'https://maps.apple.com/frame?center=40.753035,-73.981846&heading=90',
      'https://maps.apple.com/frame?coordinate=40.753035,-73.981846&pitch=45&distance=200&mode=follow',
      'https://maps.apple.com/place?place-id=I521E602783BA9605&name=The%20Met',
      'https://maps.apple.com/?auid=123&q=The%20Met',
      'https://maps.apple.com/look-around?coordinate=40.75,-73.98&heading=90',
    ]) {
      expect(ClipLink.detect(url)!.openUri('android').toString(), url);
    }
    final plain = ClipLink.detect(
      'https://maps.apple.com/frame?center=40.75,-73.98',
    )!;
    expect(plain.openUri('android').toString(), 'geo:40.75,-73.98');
  });

  test('geo coordinates must fall inside WGS84 bounds', () {
    for (final coordinates in [
      '95,200',
      '-91,0',
      '0,-181',
      '90.001,180',
      '90,180.001',
      '99999999999999999999999999999999999999,0',
    ]) {
      expect(ClipLink.detect('geo:$coordinates'), isNull);
      expect(ClipLink.detect('geo:$coordinates?q=Bank'), isNull);
    }
    for (final coordinates in ['90,180', '-90,-180', '0,180']) {
      expect(ClipLink.detect('geo:$coordinates')?.kind, ClipLinkKind.map);
    }
  });

  test('video services distinguish media from search and profile pages', () {
    for (final url in [
      'https://vimeo.com/search?q=beatles',
      'https://vimeo.com/user123',
      'https://vimeo.com/channels/staffpicks',
      'https://www.tiktok.com/@user',
      'https://www.tiktok.com/search?q=music',
      'https://www.tiktok.com/@user/video/not-an-id',
      'https://www.twitch.tv/directory',
      'https://www.twitch.tv/search?term=x',
      'https://player.twitch.tv/',
      'https://clips.twitch.tv/embed',
    ]) {
      expect(ClipLink.detect(url)?.kind, ClipLinkKind.web, reason: url);
    }
    for (final url in [
      'https://vimeo.com/123456',
      'https://vimeo.com/123456/privateHash',
      'https://player.vimeo.com/video/123456',
      'https://vimeo.com/channels/staffpicks/123456',
      'https://vimeo.com/groups/music/videos/123456',
      'https://vimeo.com/event/123456',
      'https://www.tiktok.com/@user/video/123456',
      'https://www.tiktok.com/embed/v2/123456',
      'https://vm.tiktok.com/shareToken/',
      'https://www.twitch.tv/somebody',
      'https://www.twitch.tv/videos/123456',
      'https://www.twitch.tv/somebody/clip/ClipToken',
      'https://clips.twitch.tv/ClipToken',
      'https://player.twitch.tv/?channel=somebody',
    ]) {
      expect(ClipLink.detect(url)?.kind, ClipLinkKind.video, reason: url);
    }
  });

  test('Zoom app links validate conference numbers', () {
    for (final scheme in ['zoommtg', 'zoomus']) {
      for (final id in ['', 'not-a-meeting', '123', '123456789012']) {
        expect(
          ClipLink.detect('$scheme://zoom.us/join?confno=$id')?.kind,
          ClipLinkKind.app,
        );
      }
      expect(
        ClipLink.detect('$scheme://zoom.us/join?confno=1234567890')?.kind,
        ClipLinkKind.meeting,
      );
    }
  });

  test('bare IPv4 links reject octal-looking octets', () {
    for (final host in [
      '010.0.0.1',
      '010.0.0.1:8080',
      '192.168.001.1',
      '127.000.0.1',
    ]) {
      expect(ClipLink.detect(host), isNull, reason: host);
    }
    expect(ClipLink.detect('00127.0.0.1')?.kind, isNot(ClipLinkKind.web));
    expect(ClipLink.detect('10.0.0.1')?.kind, ClipLinkKind.web);
  });

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
      expect(ClipLink.detect('555.1234')!.kind, ClipLinkKind.phone);
      // A tel: href spaced for reading, as pages often write it.
      expect(
        ClipLink.detect('tel:+1 416 555 0199')!.uri.toString(),
        'tel:+14165550199',
      );
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
        '-122.4194', // a longitude
        '-1234567', // a negative quantity
        '3.14159265', // a decimal
        '12345.67',
        '1.000.000', // thousands grouped with dots
        '12.345.678',
        '94043-1351', // a ZIP+4 code
        'www.', // no site after the prefix
        'https://.com',
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

    test('Android opens Apple Maps links as geo:, and geo: as sent', () {
      expect(
        appleClassic.openUri('android').toString(),
        'geo:48.8584,2.2945?q=48.8584%2C2.2945%28Eiffel+Tower%29',
      );
      expect(
        applePlace.openUri('android').toString(),
        'geo:37.33,-122.03?q=37.33%2C-122.03%28Apple%29',
      );
      // A native geo: link is already Android's; it opens as sent.
      expect(geo.openUri('android'), geo.uri);
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
        'https://maps.apple.com/search?query=CN+Tower&center=43.6426%2C-79.3871',
      );
      expect(google.openUri('macos'), google.uri);
    });

    test('iOS opens Apple Maps links as sent, and geo: as Apple Maps', () {
      expect(appleClassic.openUri('ios'), appleClassic.uri);
      expect(
        geo.openUri('ios').toString(),
        'https://maps.apple.com/search?query=CN+Tower&center=43.6426%2C-79.3871',
      );
    });

    test('Windows and Linux open geo: as a Google Maps search', () {
      for (final platform in ['windows', 'linux']) {
        // Scoped to the coordinates the link carries.
        expect(
          geo.openUri(platform).toString(),
          'https://www.google.com/maps/search/CN%20Tower/@43.6426,-79.3871,15z',
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
        '3 in a row',
        '2 for the road',
        '1 more way',
        '15 GB Drive',
        '3 people in line',
        '2 place settings',
        '1 route change',
        '2 items, order ID 12345',
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
      final text = phone.alternateOn('macos')!;
      expect(text.kind, ClipLinkAlternateKind.text);
      expect(text.label, 'Text');
      expect(text.uri.toString(), 'sms:+14165550199');
      expect(phone.alternateOn('linux'), isNull);
      expect(
        ClipLink.detect('https://example.com')!.alternateOn('macos'),
        isNull,
      );
    });

    test('meeting links', () {
      for (final (url, service) in [
        ('https://us02web.zoom.us/j/81234567890?pwd=abc', 'Zoom'),
        ('https://zoom.us/j/81234567890', 'Zoom'),
        ('https://zoom.us/w/81234567890', 'Zoom'),
        ('https://zoom.us/s/81234567890', 'Zoom'),
        ('https://zoom.us/my/teamroom', 'Zoom'),
        ('https://zoom.us/wc/join/81234567890', 'Zoom'),
        ('https://zoom.us/wc/81234567890/start', 'Zoom'),
        ('https://meet.google.com/abc-defg-hij', 'Google Meet'),
        ('https://g.co/meet/11thtue-trig', 'Google Meet'),
        (
          'https://teams.microsoft.com/l/meetup-join/19%3ameeting_abc/0',
          'Microsoft Teams',
        ),
        ('https://teams.live.com/meet/9876543210', 'Microsoft Teams'),
        (
          'https://teams.cloud.microsoft/l/meetup-join/19%3ameeting_abc/0',
          'Microsoft Teams',
        ),
        ('https://teams.cloud.microsoft/meet/9876543210', 'Microsoft Teams'),
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
      for (final url in [
        'https://zoom.us/wc/join/',
        'https://zoom.us/wc/join/signin',
        'https://zoom.us/wc/start',
        'https://zoom.us/wc/not-a-meeting/start',
        'https://zoom.us/j/not-a-meeting',
        'https://zoom.us/w/123',
        'https://zoom.us/s/123456789012',
        'https://g.co/meet/',
        'https://g.co/meetsetup/device',
        'https://g.co.example.com/meet/classroom',
        'https://teams.cloud.microsoft/l/meetup-join/',
        'https://teams.cloud.microsoft/meet/',
        'https://teams.cloud.microsoft/v2/',
        'https://teams.cloud.microsoft.example.com/meet/1234567890',
      ]) {
        expect(ClipLink.detect(url)!.kind, ClipLinkKind.web, reason: url);
      }
    });

    test('music links, with a way to find them elsewhere', () {
      for (final (url, service) in [
        ('https://open.spotify.com/track/4uLU6hMCjMI75M1A2tKUQC', 'Spotify'),
        ('https://music.apple.com/ca/album/x/123', 'Apple Music'),
        ('https://music.youtube.com/watch?v=abc', 'YouTube Music'),
        ('https://soundcloud.com/artist/track', 'SoundCloud'),
        ('https://tidal.com/browse/track/123', 'TIDAL'),
        ('https://www.deezer.com/track/123', 'Deezer'),
        ('https://music.amazon.ca/albums/B0', 'Amazon Music'),
        ('https://artist.bandcamp.com/album/x', 'Bandcamp'),
      ]) {
        final link = ClipLink.detect(url);
        expect(link?.kind, ClipLinkKind.music, reason: url);
        expect(link!.service, service, reason: url);
        expect(link.actionLabel, 'Open in $service');
        expect(
          link.alternateOn('android')!.uri.toString(),
          'https://song.link/$url',
          reason: url,
        );
      }

      // An Apple Music track is given to song.link as its /song/ link, not
      // the album's with the track in a query.
      expect(
        ClipLink.detect(
          'https://music.apple.com/ca/album/x/123?i=456',
        )!.alternateOn('android')!.uri.toString(),
        'https://song.link/https://music.apple.com/ca/song/456',
      );
      // Nothing for song.link to find: a podcast, a show, a playlist.
      for (final url in [
        'https://podcasts.apple.com/us/podcast/x/id1',
        'https://open.spotify.com/show/abc',
        'https://open.spotify.com/playlist/abc',
        'https://music.apple.com/us/artist/x/1',
        'spotify:user:x:playlist:y',
      ]) {
        final link = ClipLink.detect(url)!;
        expect(link.kind, ClipLinkKind.music, reason: url);
        expect(link.alternateOn('android'), isNull, reason: url);
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
        ('https://www.youtube-nocookie.com/embed/dQw4w9WgXcQ', 'YouTube'),
        ('https://vimeo.com/123456', 'Vimeo'),
        ('https://www.twitch.tv/somebody', 'Twitch'),
        ('https://www.tiktok.com/@user/video/1', 'TikTok'),
      ]) {
        final link = ClipLink.detect(url);
        expect(link?.kind, ClipLinkKind.video, reason: url);
        expect(link!.actionLabel, 'Watch on $service');
      }
      for (final url in [
        'https://www.youtube-nocookie.com/embed/',
        'https://www.youtube-nocookie.com/watch?v=dQw4w9WgXcQ',
        'https://youtube-nocookie.com.example.com/embed/dQw4w9WgXcQ',
      ]) {
        expect(ClipLink.detect(url)!.kind, ClipLinkKind.web, reason: url);
      }
    });

    test('tracking numbers, checked against their check digit', () {
      final ups = ClipLink.detect('1Z879E930346834440')!;
      expect(ups.kind, ClipLinkKind.tracking);
      expect(ups.service, 'UPS');
      expect(ups.uri.queryParameters['tracknum'], '1Z879E930346834440');
      expect(ups.actionLabel, 'Track package');
      expect(ClipLink.detect('1z879e930346834440')!.service, 'UPS');

      final usps = ClipLink.detect('9400111202555842332669')!;
      expect(usps.service, 'USPS');
      // The USPS shape with the wrong check digit: an order or account
      // number.
      expect(ClipLink.detect('9400111202555842332660'), isNull);

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
        'shortcuts://run-shortcut?name=Wipe',
        'steam://install/570',
        'raycast://extensions/x/y',
        'vscode://vscode.git/clone?url=https://evil.example/r.git',
        'cursor://anysphere.cursor-retrieval/x',
        'tg://proxy?server=1.2.3.4&port=443&secret=x',
        'tg://socks?server=1.2.3.4&port=1080',
      ]) {
        expect(ClipLink.detect(text), isNull, reason: text);
      }
      expect(
        ClipLink.detect('tg://resolve?domain=telegram')!.service,
        'Telegram',
      );
      // Editors that have no phone app.
      final editor = ClipLink.detect('vscode://file/home/u/a.dart')!;
      expect(editor.canOpenOn('macos'), isTrue);
      expect(editor.canOpenOn('android'), isFalse);
      expect(editor.canOpenOn('ios'), isFalse);
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
      // A file and line, and a four-part version or public address.
      expect(ClipLink.detect('main.dart:123'), isNull);
      expect(ClipLink.detect('app.py:42'), isNull);
      // Extensions that are also country codes.
      expect(ClipLink.detect('main.tf:12'), isNull);
      expect(ClipLink.detect('script.pl:42'), isNull);
      expect(ClipLink.detect('lib.ml:10'), isNull);
      expect(ClipLink.detect('1.0.10.27'), isNull);
      expect(ClipLink.detect('8.8.8.8'), isNull);
      expect(ClipLink.detect('8.8.8.8:53')!.kind, ClipLinkKind.web);
      for (final private in [
        '10.0.0.1',
        '172.20.1.1',
        '127.0.0.1',
        '100.101.102.103',
      ]) {
        expect(
          ClipLink.detect(private)?.kind,
          ClipLinkKind.web,
          reason: private,
        );
      }
    });
  });

  group('from review', () {
    test('regional maps.google hosts keep their map action', () {
      for (final host in [
        'maps.google.com',
        'maps.google.co.uk',
        'maps.google.com.au',
        'maps.google.ca',
      ]) {
        final link = ClipLink.detect('https://$host/?q=London')!;
        expect(link.kind, ClipLinkKind.map, reason: host);
        expect(link.label, 'London');
        expect(link.actionLabel, 'Open in Maps');
        expect(link.openUri('android'), link.uri);
      }
      for (final host in [
        'maps.google.co.uk.evil',
        'maps.google.com.au.evil',
        'maps.evilgoogle.co.uk',
        'maps.evil.google.com',
      ]) {
        expect(
          ClipLink.detect('https://$host/maps/search/London')!.kind,
          ClipLinkKind.web,
          reason: host,
        );
      }
      expect(
        ClipLink.detect('https://www.google.co.uk/?q=London')!.kind,
        ClipLinkKind.web,
      );
    });

    test('email dots and domain hyphens must be inside their components', () {
      for (final address in [
        'first..last@example.com',
        '.first@example.com',
        'first.@example.com',
        'user@-example.com',
        'user@example-.com',
        'user@sub.-example.com',
        'user@sub-.example.com',
        'user@example..com',
        'user@example.xn--abc-',
      ]) {
        expect(ClipLink.detect(address), isNull, reason: address);
        expect(ClipLink.detect('mailto:$address'), isNull, reason: address);
        expect(
          ClipLink.detect('mailto:valid@example.com,$address'),
          isNull,
          reason: address,
        );
      }
      for (final address in [
        'first.last+tag@sub-domain.example.com',
        'a_b%tag@example.co.uk',
        'user@xn--80a1acny.xn--p1ai',
        'a@b.co',
      ]) {
        expect(ClipLink.detect(address)?.kind, ClipLinkKind.email);
        expect(
          ClipLink.detect('mailto:${Uri.encodeComponent(address)}')?.kind,
          ClipLinkKind.email,
        );
      }
      expect(ClipLink.detect('mailto:first%2E%2Elast@example.com'), isNull);
    });

    test('Android retains Look Around as a panorama', () {
      final link = ClipLink.detect(
        'https://maps.apple.com/look-around?coordinate=48.8584,2.2945',
      )!;
      final opened = link.openUri('android');
      expect(opened.scheme, 'https');
      expect(opened.host, 'www.google.com');
      expect(opened.path, '/maps/@');
      expect(opened.queryParameters, {
        'api': '1',
        'map_action': 'pano',
        'viewpoint': '48.8584,2.2945',
      });
      for (final platform in ['ios', 'macos', 'windows', 'linux']) {
        expect(link.openUri(platform), link.uri);
      }
      // An address or Apple place ID cannot provide a Street View viewpoint.
      for (final query in [
        'address=Eiffel%20Tower',
        'place-id=IBE1F65094A7A13B1',
        'coordinate=invalid&address=Eiffel%20Tower',
      ]) {
        final unresolved = ClipLink.detect(
          'https://maps.apple.com/look-around?$query',
        )!;
        expect(unresolved.openUri('android'), unresolved.uri);
      }
    });

    test('Android retains route stops and supported avoid preferences', () {
      final route = ClipLink.detect(
        'https://maps.apple.com/directions?source=A&destination=C'
        '&waypoint=B&mode=driving&avoid=tolls',
      )!;
      expect(route.openUri('android').queryParameters, {
        'api': '1',
        'origin': 'A',
        'destination': 'C',
        'travelmode': 'driving',
        'waypoints': 'B',
        'avoid': 'tolls',
      });

      final multiple = ClipLink.detect(
        'https://maps.apple.com/directions?destination=End'
        '&waypoint=First%20Stop&waypoint=34.99,-106.61&waypoint='
        '&avoid=tolls,stairs&avoid=highways&avoid=tolls',
      )!;
      expect(multiple.openUri('android').queryParameters, {
        'api': '1',
        'destination': 'End',
        'waypoints': 'First Stop|34.99,-106.61',
        'avoid': 'tolls,highways',
      });
      expect(multiple.openUri('ios'), multiple.uri);

      final unsupported = ClipLink.detect(
        'https://maps.apple.com/directions?destination=End'
        '&waypoint=&avoid=stairs,busy-roads',
      )!;
      expect(unsupported.openUri('android').queryParameters, {
        'api': '1',
        'destination': 'End',
      });
    });

    test('Android rewrites an Apple frame with only a center', () {
      final frame = ClipLink.detect(
        'https://maps.apple.com/frame?center=40.753035,-73.981846',
      )!;
      expect(frame.kind, ClipLinkKind.map);
      expect(frame.openUri('android').toString(), 'geo:40.753035,-73.981846');
      expect(frame.openUri('ios'), frame.uri);
    });

    test('labeled geo queries retain the pin and label on Apple devices', () {
      for (final input in [
        'geo:0,0?q=34.99,-106.61(Treasure)',
        'geo:51.5,-0.12?q=34.99%2C-106.61%28Treasure%29',
      ]) {
        final pin = ClipLink.detect(input)!;
        expect(pin.label, 'Treasure');
        expect(pin.openUri('android'), pin.uri);
        for (final platform in ['ios', 'macos']) {
          final opened = pin.openUri(platform);
          expect(opened.queryParameters, {
            'q': 'Treasure',
            'll': '34.99,-106.61',
          });
        }
      }
      final escaped = ClipLink.detect(
        'geo:0,0?q=0,0%28A%20%26%20B%20%28home%29%29',
      )!;
      expect(escaped.openUri('ios').queryParameters, {
        'q': 'A & B (home)',
        'll': '0,0',
      });
      final unlabeled = ClipLink.detect('geo:0,0?q=34.99,-106.61()')!;
      expect(unlabeled.openUri('ios').queryParameters, {'ll': '34.99,-106.61'});
    });

    test('formatted ISBN-10 identifiers are not phone numbers', () {
      for (final isbn in ['0-306-40615-2', '0 306 40615 2', '1-4028-9462-7']) {
        expect(ClipLink.detect(isbn), isNull, reason: isbn);
      }
      // A checksum mismatch and ordinary phone grouping must still work.
      expect(ClipLink.detect('0-306-40615-3')?.kind, ClipLinkKind.phone);
      expect(ClipLink.detect('416-555-0199')?.kind, ClipLinkKind.phone);
      expect(ClipLink.detect('tel:0-306-40615-2')?.kind, ClipLinkKind.phone);
      expect(ClipLink.detect('+0-306-40615-2')?.kind, ClipLinkKind.phone);
    });

    test('Android keeps Apple place coordinates with an ambiguous label', () {
      for (final url in [
        'https://maps.apple.com/?q=Home&ll=37.33,-122.03',
        'https://maps.apple.com/place?name=Home&coordinate=37.33,-122.03',
        'https://maps.apple.com/?q=Home&ll=37.33,-122.03&sll=51.507984,-0.128015',
      ]) {
        final link = ClipLink.detect(url)!;
        final opened = link.openUri('android');
        // Android's coordinate(label) query selects a pin; a bare label
        // searches for a different place near the geo: coordinates.
        expect(opened.scheme, 'geo');
        expect(opened.path, '37.33,-122.03');
        expect(opened.queryParameters['q'], '37.33,-122.03(Home)');
      }
    });

    test('Android keeps Apple searches and unnamed coordinates', () {
      final search = ClipLink.detect('https://maps.apple.com/?q=Coffee')!;
      expect(search.openUri('android').path, '0,0');
      expect(search.openUri('android').queryParameters['q'], 'Coffee');

      final coordinates = ClipLink.detect(
        'https://maps.apple.com/place?coordinate=37.33,-122.03',
      )!;
      expect(coordinates.openUri('android').toString(), 'geo:37.33,-122.03');
    });

    test('a clip that cannot be decoded stays text rather than throwing', () {
      for (final text in [
        'tel:%FF',
        'mailto:%FF@example.com',
        'https://maps.apple.com/?q=%FF',
        'geo:0,0?q=%FF',
      ]) {
        expect(() => ClipLink.detect(text), returnsNormally, reason: text);
      }
      expect(ClipLink.detect('tel:%FF'), isNull);
    });

    test('tel: parameters are kept', () {
      final link = ClipLink.detect('tel:+1-201-555-0123;ext=456')!;
      expect(link.kind, ClipLinkKind.phone);
      expect(link.uri.toString(), 'tel:+1-201-555-0123;ext=456');
      expect(
        link.alternateOn('android')!.uri.toString(),
        'sms:+1-201-555-0123',
      );
      expect(ClipLink.detect('tel:12;ext=4')?.kind, ClipLinkKind.phone);
    });

    test('Apple Maps directions open as Google Maps directions on Android', () {
      final route = ClipLink.detect(
        'https://maps.apple.com/?saddr=Current+Location&daddr=Airport&dirflg=d',
      )!;
      expect(
        route.openUri('android').toString(),
        'https://www.google.com/maps/dir/?api=1&destination=Airport'
        '&travelmode=driving',
      );
      final fromHome = ClipLink.detect(
        'https://maps.apple.com/?saddr=Home&daddr=Work&dirflg=w',
      )!;
      expect(fromHome.openUri('android').queryParameters, {
        'api': '1',
        'origin': 'Home',
        'destination': 'Work',
        'travelmode': 'walking',
      });
    });

    test('a four-by-four phone number is not a range', () {
      expect(ClipLink.detect('2123-4567')!.kind, ClipLinkKind.phone);
      expect(ClipLink.detect('1000-2000'), isNull);
    });

    test('only Google domains are Google Maps', () {
      expect(
        ClipLink.detect('https://google.com.evil/maps/search/Bank')!.kind,
        ClipLinkKind.web,
      );
      expect(
        ClipLink.detect('https://www.google.co.uk/maps/search/Bank')!.kind,
        ClipLinkKind.map,
      );
      expect(
        ClipLink.detect('https://www.google.ca/maps/place/CN+Tower')!.kind,
        ClipLinkKind.map,
      );
    });

    test('IPv6 web links', () {
      final link = ClipLink.detect('https://[2001:db8::1]/status')!;
      expect(link.kind, ClipLinkKind.web);
    });

    test('mailto: links with several recipients', () {
      final link = ClipLink.detect(
        'mailto:alice@example.com,bob@example.com?subject=Update',
      )!;
      expect(link.kind, ClipLinkKind.email);
      expect(link.label, 'alice@example.com, bob@example.com');
      expect(link.uri.queryParameters['subject'], 'Update');
      expect(ClipLink.detect('mailto:alice@example.com,bob'), isNull);
    });

    test('mailto: links with no recipient open a draft', () {
      final link = ClipLink.detect('mailto:?subject=Feedback')!;
      expect(link.kind, ClipLinkKind.email);
      expect(link.label, 'New email');
      expect(link.uri.queryParameters['subject'], 'Feedback');
      expect(ClipLink.detect('mailto:'), isNull);
    });

    test('native geo: links open as sent on Android', () {
      for (final text in [
        'geo:43.6426,-79.3871?z=18',
        'geo:43.6426,-79.3871;u=35',
      ]) {
        final link = ClipLink.detect(text)!;
        expect(link.openUri('android'), link.uri, reason: text);
      }
    });

    test('a Social Security number is not a phone number', () {
      expect(ClipLink.detect('123-45-6789'), isNull);
      expect(ClipLink.detect('123-456-7890')?.kind, ClipLinkKind.phone);
    });

    test('punycode top-level domains in email addresses', () {
      expect(
        ClipLink.detect('user@xn--80a1acny.xn--p1ai')?.kind,
        ClipLinkKind.email,
      );
      expect(ClipLink.detect('user@example.xn--'), isNull);
    });

    test('3D geo: links keep their place and open as sent on Android', () {
      final link = ClipLink.detect('geo:48.2010,16.3695,183')!;
      expect(link.kind, ClipLinkKind.map);
      expect(link.label, '48.2010,16.3695');
      expect(link.openUri('android'), link.uri);
      expect(
        link.openUri('windows').queryParameters['query'],
        '48.2010,16.3695',
      );
      // A 2D link keeps both coordinates.
      expect(
        ClipLink.detect('geo:43.6426,-79.3871')!.label,
        '43.6426,-79.3871',
      );
    });

    test('numbers spaced with no-break spaces', () {
      for (final text in [
        '+33\u00A01\u00A042\u00A068\u00A053\u00A000',
        '+33\u202F1 42 68 53 00',
      ]) {
        expect(ClipLink.detect(text)?.kind, ClipLinkKind.phone, reason: text);
      }
      expect(
        ClipLink.detect(
          '+33\u00A01\u00A042\u00A068\u00A053\u00A000',
        )!.uri.toString(),
        'tel:+33142685300',
      );
    });

    test('an Apple Maps search keeps its centre on Android', () {
      for (final url in [
        'https://maps.apple.com/search?query=pizza&center=51.507984,-0.128015',
        'https://maps.apple.com/?q=pizza&sll=51.507984,-0.128015',
      ]) {
        final search = ClipLink.detect(url)!;
        expect(
          search.openUri('android').toString(),
          'geo:51.507984,-0.128015?q=pizza',
          reason: url,
        );
      }
    });

    test('a geo: search without coordinates stays an API search', () {
      expect(
        ClipLink.detect('geo:0,0?q=CN%20Tower')!.openUri('linux').toString(),
        'https://www.google.com/maps/search/?api=1&query=CN+Tower',
      );
    });

    test('a card number written in groups is not a phone number', () {
      expect(ClipLink.detect('3782 822463 10005'), isNull);
      // A long international number still is.
      expect(ClipLink.detect('+44 20 7946 0958 123')?.kind, ClipLinkKind.phone);
    });
  });

  group('from review, more kinds', () {
    test('only real Amazon domains are Amazon Music', () {
      expect(
        ClipLink.detect('https://music.amazon.attacker.com/track')?.service,
        isNot('Amazon Music'),
      );
      expect(
        ClipLink.detect('https://music.amazon.co.uk/albums/B0')?.service,
        'Amazon Music',
      );
    });

    test('app links that perform actions stay text', () {
      for (final text in [
        'drafts://x-callback-url/runAction?action=Delete',
        'bear://x-callback-url/trash?id=1',
        'things:///add?title=x',
        'todoist://addtask?content=x',
        'obsidian://new?vault=Notes&name=x',
        'craftdocs://createdocument?spaceId=1',
      ]) {
        expect(
          ClipLink.detect(text)?.kind,
          isNot(ClipLinkKind.app),
          reason: text,
        );
      }
      for (final text in [
        'drafts://open?uuid=1',
        'bear://x-callback-url/open-note?id=1',
        'things:///show?id=today',
        'todoist://today',
        'obsidian://open?vault=Notes&file=Inbox',
        'craftdocs://open?blockId=1&spaceId=2',
      ]) {
        expect(ClipLink.detect(text)?.kind, ClipLinkKind.app, reason: text);
      }
    });

    test('navigation routes need their destination', () {
      for (final text in [
        'todoist://task',
        'todoist://project?id=%20',
        'drafts://open',
        'drafts://x-callback-url/open?uuid=',
        'craftdocs://open',
        'craftdocs://open?blockId=1',
        'craftdocs://open?spaceId=2',
        'bear://x-callback-url/open-note',
        'bear://x-callback-url/open-tag',
        'things:///show',
        'obsidian://open',
        'tg://resolve',
        'tg://resolve?domain=',
        'tg://resolve?domain=%20&profile',
        'tg://join',
        'tg://join?invite=',
        'tg://privatepost?channel=123',
        'tg://privatepost?post=456',
        'sgnl://addstickers',
        'sgnl://addstickers?pack_id=abc',
        'sgnl://addstickers?pack_id=abc&pack_key=',
        'sgnl://signal.me/',
        'sgnl://signal.me/#p/',
        'sgnl://signal.me/#eu/',
        'sgnl://signal.me/#notes',
        'sgnl://signal.group/',
      ]) {
        expect(ClipLink.detect(text), isNull, reason: text);
      }
      for (final text in [
        'tg://resolve?domain=telegram&profile',
        'tg://join?invite=inviteHash',
        'tg://privatepost?channel=123&post=456',
        'sgnl://addstickers?pack_id=abc&pack_key=def',
        'sgnl://signal.me/#p/+15555550123',
        'sgnl://signal.me/#eu/usernameToken',
        'sgnl://signal.group/#groupInviteToken',
        'todoist://today',
        'todoist://upcoming',
        'todoist://inbox',
        'todoist://task?id=1',
        'todoist://project?id=2',
        'drafts://open?title=Notes&marker=Introduction',
        'craftdocs://open?blockId=1&spaceId=2',
        'bear://x-callback-url/open-note?title=Notes',
        'bear://x-callback-url/open-tag?name=work',
        'obsidian://open?vault=Notes',
      ]) {
        expect(ClipLink.detect(text)?.kind, ClipLinkKind.app, reason: text);
      }
    });

    test('navigation routes that are told to act stay text', () {
      for (final text in [
        'drafts://open?uuid=1&action=Delete',
        'bear://x-callback-url/open-note?id=1&x-success=shortcuts://run',
        'drafts://x-callback-url/open?uuid=1&x-error=bear://x',
        'bear://x-callback-url/open-note?id=1&pin=yes',
      ]) {
        expect(
          ClipLink.detect(text)?.kind,
          isNot(ClipLinkKind.app),
          reason: text,
        );
      }
    });

    test("Whereby's own pages are not meetings", () {
      expect(
        ClipLink.detect('https://whereby.com/information/tos')?.kind,
        isNot(ClipLinkKind.meeting),
      );
      expect(
        ClipLink.detect('https://whereby.com/pricing')?.kind,
        isNot(ClipLinkKind.meeting),
      );
      expect(
        ClipLink.detect('https://whereby.com/team-standup')?.kind,
        ClipLinkKind.meeting,
      );
    });

    test('a file and line is not a host and port', () {
      for (final text in [
        'schema.sql:42',
        'Component.vue:80',
        'build.gradle:12',
      ]) {
        expect(ClipLink.detect(text), isNull, reason: text);
      }
      expect(
        ClipLink.detect('staging.example.com:8443/admin')?.kind,
        ClipLinkKind.web,
      );
      expect(ClipLink.detect('example.io:3000')?.kind, ClipLinkKind.web);
    });

    test('more from review', () {
      // Multicast and broadcast are not machines to open a page on.
      expect(ClipLink.detect('224.0.0.1'), isNull);
      expect(ClipLink.detect('255.255.255.255'), isNull);
      expect(ClipLink.detect('192.168.1.1')?.kind, ClipLinkKind.web);
      // An encoded `;` is still a parameter delimiter for Text.
      final encoded = ClipLink.detect('tel:5550123%3Bphone-context=+1-201')!;
      expect(encoded.kind, ClipLinkKind.phone);
      expect(encoded.alternateOn('android'), isNull);
      // Parcelforce numbers go to Parcelforce.
      expect(ClipLink.detect('EC080250821GB')!.uri.host, 'www.parcelforce.com');
      // A Teams chat is the app; a meeting link is a meeting.
      expect(
        ClipLink.detect(
          'msteams://teams.microsoft.com/l/chat/0/0?users=a@example.com',
        )?.kind,
        ClipLinkKind.app,
      );
      expect(
        ClipLink.detect(
          'msteams://teams.microsoft.com/l/meetup-join/19%3ameeting_x/0',
        )?.kind,
        ClipLinkKind.meeting,
      );
    });

    test('Teams /meet/ links, ports past 65535, accented street names', () {
      expect(
        ClipLink.detect(
          'https://teams.microsoft.com/meet/22503094877696?p=abc',
        )?.kind,
        ClipLinkKind.meeting,
      );
      expect(ClipLink.detect('localhost:99999'), isNull);
      expect(ClipLink.detect('192.168.1.1:70000'), isNull);
      expect(ClipLink.detect('localhost:65535')?.kind, ClipLinkKind.web);
      expect(ClipLink.detect('123 Église St')?.kind, ClipLinkKind.map);
    });

    test('music home pages are pages; Classroom Meet links are meetings', () {
      final home = ClipLink.detect('https://open.spotify.com/')!;
      expect(home.kind, ClipLinkKind.web);
      expect(home.alternateOn('android'), isNull);
      expect(
        ClipLink.detect('https://open.spotify.com/track/abc')?.kind,
        ClipLinkKind.music,
      );
      expect(
        ClipLink.detect('https://meet.google.com/lookup/abcdef123')?.kind,
        ClipLinkKind.meeting,
      );
    });

    test('port 0, Zoom Web App, government Teams, query-only local URLs', () {
      expect(ClipLink.detect('localhost:0'), isNull);
      expect(ClipLink.detect('192.168.1.1:0'), isNull);
      expect(
        ClipLink.detect('https://zoom.us/wc/123456789/join')?.kind,
        ClipLinkKind.meeting,
      );
      expect(
        ClipLink.detect(
          'https://gov.teams.microsoft.us/l/meetup-join/19%3ax/0',
        )?.kind,
        ClipLinkKind.meeting,
      );
      for (final text in [
        'localhost:3000?debug=1',
        'printer.local?admin=1',
        '192.168.1.1#status',
      ]) {
        expect(ClipLink.detect(text)?.kind, ClipLinkKind.web, reason: text);
      }
    });

    test('Whereby rooms on a Business subdomain', () {
      expect(
        ClipLink.detect('https://company.whereby.com/team-standup')?.kind,
        ClipLinkKind.meeting,
      );
      expect(
        ClipLink.detect('https://support.whereby.com/articles')?.kind,
        isNot(ClipLinkKind.meeting),
      );
    });

    test('tracking numbers written in groups', () {
      final s10 = ClipLink.detect('EC 080 250 821 GB')!;
      expect(s10.kind, ClipLinkKind.tracking);
      expect(s10.uri.host, 'www.parcelforce.com');
      // Only digits and letters in groups; anything else stays text.
      expect(ClipLink.detect('EC-080-250-821-GB'), isNull);
      // However it was spaced.
      expect(
        ClipLink.detect('EC\u00A0080\u00A0250  821\u00A0GB')?.kind,
        ClipLinkKind.tracking,
      );
    });

    test('Apple-only apps, video home pages, empty app links, short ports', () {
      final things = ClipLink.detect('things:///show?id=today')!;
      expect(things.canOpenOn('macos'), isTrue);
      expect(things.canOpenOn('ios'), isTrue);
      for (final platform in ['windows', 'android', 'linux']) {
        expect(things.canOpenOn(platform), isFalse, reason: platform);
      }
      expect(ClipLink.detect('https://youtube.com/')?.kind, ClipLinkKind.web);
      expect(
        ClipLink.detect('https://youtube.com/watch?v=abc')?.kind,
        ClipLinkKind.video,
      );
      expect(
        ClipLink.detect('https://cacb.zoomgov.com/j/1617514241')?.kind,
        ClipLinkKind.meeting,
      );
      expect(ClipLink.detect('zoommtg://'), isNull);
      expect(ClipLink.detect('spotify://'), isNull);
      expect(ClipLink.detect('example.com:8/status')?.kind, ClipLinkKind.web);
      expect(ClipLink.detect('main.c:8'), isNull);
    });

    test(
      'Classical, FaceTime, local hosts, wrapped tracking, YouTube playlists',
      () {
        expect(
          ClipLink.detect(
            'https://classical.music.apple.com/us/album/1',
          )?.service,
          'Apple Music',
        );
        expect(
          ClipLink.detect('https://facetime.apple.com/join#v=1&p=abc')?.kind,
          ClipLinkKind.meeting,
        );
        expect(
          ClipLink.detect('https://facetime.apple.com/')?.kind,
          isNot(ClipLinkKind.meeting),
        );
        final audio = ClipLink.detect('facetime-audio:user@example.com')!;
        expect(audio.kind, ClipLinkKind.meeting);
        expect(audio.canOpenOn('ios'), isTrue);
        expect(audio.canOpenOn('android'), isFalse);
        for (final text in [
          '[::1]:3000',
          '[fd00::1]:8080/admin',
          'tenant.localhost:3000',
        ]) {
          expect(ClipLink.detect(text)?.kind, ClipLinkKind.web, reason: text);
        }
        for (final text in ['224.0.0.1:8080', '255.255.255.255/status']) {
          expect(ClipLink.detect(text), isNull, reason: text);
        }
        expect(ClipLink.detect('8.8.8.8:53/x')?.kind, ClipLinkKind.web);
        expect(
          ClipLink.detect('EC 080 250\n821 GB')?.kind,
          ClipLinkKind.tracking,
        );
        expect(
          ClipLink.detect(
            'https://music.youtube.com/playlist?list=PLabc',
          )!.alternateOn('android'),
          isNull,
        );
        expect(
          ClipLink.detect(
            'https://music.youtube.com/playlist?list=OLAK5uyabc',
          )!.alternateOn('android'),
          isNotNull,
        );
        expect(ClipLink.detect('Alte Dorfstraße 5')?.kind, ClipLinkKind.map);
        expect(ClipLink.detect('Am Alten Weg 3')?.kind, ClipLinkKind.map);
        expect(ClipLink.detect('Weg 3'), isNull);
        expect(ClipLink.detect('Hauptstraße 5-7')?.kind, ClipLinkKind.map);

        // A meeting link needs the meeting itself, not just its route.
        for (final text in [
          'https://zoom.us/j/',
          'https://zoom.us/my/',
          'zoommtg://zoom.us/join',
          'zoommtg://zoom.us/join?action=join',
          'https://teams.microsoft.com/meet/',
          'https://teams.live.com/meet',
          'https://teams.microsoft.com/l/meetup-join/',
          'https://teams.microsoft.com/l/meetup-join-notes',
          'msteams:/l/meeting/',
          'msteams:/l/call/',
          'https://acme.webex.com/meet/',
          'https://acme.webex.com/join/',
          'https://acme.webex.com/acme/j.php-notes',
          'https://acme.webex.com/j.php',
          'https://facetime.apple.com/joinery',
          'https://facetime.apple.com/join',
          'https://facetime.apple.com/join/unrelated#v=1&p=abc',
          'https://facetime.apple.com/join#notes',
          'https://meet.google.com/abc-defg-hij-notes',
          'https://meet.google.com/abc-defg-hij/unrelated',
        ]) {
          expect(
            ClipLink.detect(text)?.kind,
            isNot(ClipLinkKind.meeting),
            reason: text,
          );
        }
        for (final text in [
          'https://zoom.us/my/alice',
          'https://acme.webex.com/acme/j.php?MTID=m123',
          'https://meet.google.com/abc-defg-hij/',
          'https://whereby.com/team-standup/',
        ]) {
          expect(
            ClipLink.detect(text)?.kind,
            ClipLinkKind.meeting,
            reason: text,
          );
        }

        // A service's help, developer and API sites are pages about it.
        for (final (text, kind) in [
          ('https://help.twitch.tv/s/article/abc', ClipLinkKind.video),
          ('https://help.vimeo.com/hc/en-us/articles/123', ClipLinkKind.video),
          (
            'https://help.soundcloud.com/hc/en-us/articles/115003449627',
            ClipLinkKind.music,
          ),
          ('https://api.soundcloud.com/tracks/123', ClipLinkKind.music),
          ('https://api-v2.soundcloud.com/tracks/123', ClipLinkKind.music),
        ]) {
          expect(ClipLink.detect(text)?.kind, isNot(kind), reason: text);
        }

        for (final text in [
          'tg://resolve?domain=telegram&profile',
          'sgnl://signal.me/#p/+15555550123',
        ]) {
          expect(ClipLink.detect(text)?.kind, ClipLinkKind.app, reason: text);
        }
        expect(
          ClipLink.detect('https://pandora.app.link/AbCdEf')?.service,
          'Pandora',
        );

        expect(
          ClipLink.detect('example.com:443/status')!.uri.toString(),
          'https://example.com/status',
        );
        for (final text in [
          'example.com:8080/app.js:42',
          '[::ffff:192.168.1.1]:80',
        ]) {
          expect(ClipLink.detect(text)?.kind, ClipLinkKind.web, reason: text);
        }
        for (final text in [
          'main.dart:120',
          'Main.hs:42',
          'Program.fs:8',
          'script.jl:7',
          '[ff02::1]:8080',
          '[::]:3000',
          '[::ffff:224.0.0.1]:8080',
          '[2001:db8::1]:8080',
          '[3fff::1]:8080',
          '192.0.2.1:8080',
          '198.51.100.1/status',
          '203.0.113.1:80',
          'zoommtg:///',
          'spotify:/',
          'sgnl://linkdevice?uuid=abc&pub_key=def',
        ]) {
          expect(ClipLink.detect(text), isNull, reason: text);
        }

        // song.link only for a song or album.
        for (final text in [
          'https://open.spotify.com/collection/tracks',
          'https://open.spotify.com/track',
          'https://music.apple.com/us/station/apple-music-1/ra.978194965',
          'https://music.apple.com/us/browse',
          'https://music.apple.com/us/playlist/album/pl.abc',
          'https://artist.bandcamp.com/merch/shirt',
          'https://www.deezer.com/search/beatles',
          'https://www.deezer.com/album/',
          'https://tidal.com/browse/mix/abc',
          'https://soundcloud.com/forss',
          'https://soundcloud.com/forss/likes',
          'https://soundcloud.com/forss/sets/soulhack',
          'https://soundcloud.com/search/sounds?q=beatles',
          'https://music.youtube.com/watch',
          'https://music.youtube.com/watchlater?v=abc',
          'https://music.youtube.com/channel/UCabc',
          'https://www.pandora.com/search/subscriptions/all',
          'https://www.pandora.com/artist/the-beatles/ARabc123',
          'https://www.pandora.com/track/',
          'https://www.pandora.com/album/',
          'https://www.pandora.com/track/ALxpJ9fhV534Xhg',
          'https://www.pandora.com/album/TR92bl4n9wPPd96',
          'https://www.pandora.com/track/not-an-id',
        ]) {
          expect(
            ClipLink.detect(text)!.alternateOn('android'),
            isNull,
            reason: text,
          );
        }
        for (final text in [
          'https://open.spotify.com/intl-de/track/abc',
          'https://open.spotify.com/embed/track/0Lr4kGOYn9l83EjuK6cZFQ',
          'spotify:album:abc',
          'https://artist.bandcamp.com/track/song',
          'https://www.deezer.com/us/album/302127',
          'https://soundcloud.com/forss/flickermood',
          'https://on.soundcloud.com/AbCd',
          'https://www.pandora.com/artist/the-beatles/abbey-road/come-together/TRabc123',
          'https://www.pandora.com/artist/the-beatles/abbey-road/ALabc123',
          'https://www.pandora.com/track/TR92bl4n9wPPd96',
          'https://www.pandora.com/album/ALxpJ9fhV534Xhg',
          'https://pandora.app.link/AbCdEf',
        ]) {
          expect(
            ClipLink.detect(text)!.alternateOn('android'),
            isNotNull,
            reason: text,
          );
        }
      },
    );

    test('DMS minutes and seconds must be under 60', () {
      expect(ClipLink.detect('43°99\'00"N 79°23\'00"W'), isNull);
      expect(ClipLink.detect('43°38\'60"N 79°23\'00"W'), isNull);
    });

    test('0,0 coordinates are a placeholder, not a place', () {
      expect(ClipLink.detect('0.000, 0.000'), isNull);
    });

    test('no Text for a number with a phone context', () {
      final local = ClipLink.detect('tel:5550123;phone-context=+1-201')!;
      expect(local.kind, ClipLinkKind.phone);
      expect(local.alternateOn('android'), isNull);
      expect(
        ClipLink.detect('tel:+12015550123;ext=4')!.alternateOn('android'),
        isNotNull,
      );
    });
  });
  test('all numeric zero geo centers leave searches unscoped', () {
    for (final zero in ['0,0', '0.0,0.0', '-0,0.00', '-0.0,-0.0']) {
      final link = ClipLink.detect('geo:$zero?q=CN%20Tower')!;
      expect(link.openUri('ios').queryParameters, {'q': 'CN Tower'});
      expect(link.openUri('linux').queryParameters, {
        'api': '1',
        'query': 'CN Tower',
      });
    }
  });

  test('nearby geo searches retain a search center on Apple platforms', () {
    final search = ClipLink.detect('geo:37.7749,-122.4194?q=Coffee')!;
    for (final platform in ['ios', 'macos']) {
      final opened = search.openUri(platform);
      expect(opened.host, 'maps.apple.com');
      expect(opened.path, '/search');
      expect(opened.queryParameters, {
        'query': 'Coffee',
        'center': '37.7749,-122.4194',
      });
    }
    final pin = ClipLink.detect('geo:0,0?q=37.7749,-122.4194')!;
    expect(pin.openUri('ios').queryParameters, {'ll': '37.7749,-122.4194'});
  });

  test(
    'explicit telephone URIs support private and service number lengths',
    () {
      for (final target in [
        'tel:911',
        'tel:1',
        'tel:1234;phone-context=example.com',
        'tel:1234567890123456;phone-context=example.com',
      ]) {
        final link = ClipLink.detect(target)!;
        expect(link.kind, ClipLinkKind.phone);
        expect(link.uri.toString(), target);
      }
      expect(ClipLink.detect('1234'), isNull);
      expect(ClipLink.detect('tel:'), isNull);
    },
  );
  test(
    'explicit local telephone identifiers preserve service and hex symbols',
    () {
      for (final target in [
        'tel:*123%23;phone-context=example.com',
        'tel:AB12%23;phone-context=example.com',
        'tel:aBcD;phone-context=example.com',
        'tel:*123%23',
      ]) {
        final link = ClipLink.detect(target)!;
        expect(link.kind, ClipLinkKind.phone);
        expect(link.uri.toString(), target);
      }
      for (final text in [
        '*123#',
        'AB12#',
        'tel:+AB',
        'tel:+1*2',
        'tel:(-.)',
      ]) {
        expect(ClipLink.detect(text), isNull, reason: text);
      }
    },
  );
}
