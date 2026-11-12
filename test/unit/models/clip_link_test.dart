import 'package:flutter_test/flutter_test.dart';
import 'package:ghostcopy/models/clip_link.dart';

void main() {
  test('spaced explicit telephone links retain their parameters', () {
    for (final (text, expected) in [
      ('tel:+1 416 555 0199;ext=456', 'tel:+14165550199;ext=456'),
      (
        'tel:123 456;phone-context=example.com',
        'tel:123456;phone-context=example.com',
      ),
      (
        'tel:* 123%23;phone-context=example.com',
        'tel:*123%23;phone-context=example.com',
      ),
    ]) {
      final link = ClipLink.detect(text)!;
      expect(link.kind, ClipLinkKind.phone);
      expect(link.uri.toString(), expected);
    }
    expect(ClipLink.detect('tel:+1 416 555 0199;ext=4 56'), isNull);
  });

  test('fully qualified map hosts keep map actions and original web URI', () {
    for (final text in [
      'https://maps.apple.com./?q=London',
      'https://maps.google.com./?q=London',
    ]) {
      final link = ClipLink.detect(text)!;
      expect(link.kind, ClipLinkKind.map);
      expect(link.uri.toString(), text);
      if (text.contains('apple')) {
        expect(link.openUri('android').toString(), 'geo:0,0?q=London');
      } else {
        expect(link.openUri('android').toString(), text);
      }
    }
    expect(
      ClipLink.detect('https://maps.apple.com.evil./?q=London')?.kind,
      ClipLinkKind.web,
    );
  });

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
        '192.168.1.10',
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
