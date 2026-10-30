/// What kind of openable thing a clip is.
enum ClipLinkKind {
  web,
  map,
  email,
  phone,
  meeting,
  music,
  video,
  tracking,
  app,
}

/// A second thing to do with a link, beside opening it: text a phone number,
/// find a song on another service.
class ClipLinkAlternate {
  const ClipLinkAlternate(this.label, this.uri);

  final String label;
  final Uri uri;
}

/// A text clip that is, in its entirety, something the receiving device can
/// open: a web page, a place or street address, an email address, a phone
/// number, a meeting, a song or video, a parcel to track, or a link into an
/// app.
///
/// Whole-clip only. A paragraph that happens to contain a URL stays a
/// paragraph - the row would otherwise have to pick one of several links, and
/// "Open" on a clip that is mostly prose is not what anyone copied it for.
///
/// Opening goes through [openUri], which rewrites a map link into whatever the
/// receiving platform's maps app actually answers to. That is the part a
/// single-platform clipboard never needs: an Apple Maps link sent from a Mac
/// opens in a browser tab on Android unless it is turned into a `geo:` URI
/// first.
class ClipLink {
  const ClipLink._(this.kind, this.uri, this.label, {this.service});

  ClipLink._parcel(String carrier, Uri page, String number)
    : this._(ClipLinkKind.tracking, page, number, service: carrier);

  final ClipLinkKind kind;

  /// The service or app a link belongs to, where the kind has one: "Zoom",
  /// "Spotify", "YouTube", "UPS", "Obsidian".
  final String? service;

  /// The link as sent, with a scheme added where the clip had none
  /// (`www.example.com`, a bare address, a formatted phone number), or the
  /// link a clip that is not one stands for: `geo:` for a street address or
  /// coordinates, the carrier's page for a tracking number.
  final Uri uri;

  /// Short text naming what the link points at: the site's host, the place,
  /// the address, the number.
  final String label;

  /// Longest clip considered. Real links can be long - a Google Maps URL with
  /// its data blob runs well past 500 characters - but anything near this is
  /// not a single link someone wants a button for.
  static const maxLength = 2048;

  static final _whitespace = RegExp(r'\s');
  static final _email = RegExp(
    r'^[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}$',
  );
  static final _phoneChars = RegExp(r'^\+?[0-9()\-. ]+$');
  static final _nonDigit = RegExp(r'\D');
  static final _ipv4 = RegExp(r'^\d{1,3}(\.\d{1,3}){3}$');
  static final _date = RegExp(
    r'^(\d{4}[-./]\d{1,2}[-./]\d{1,2}|\d{1,2}[-./]\d{1,2}[-./]\d{2,4})$',
  );
  static final _latLng = RegExp(r'^-?\d+(\.\d+)?,-?\d+(\.\d+)?$');

  /// The link this clip is, or null when it is not one.
  static ClipLink? detect(String content) {
    final text = content.trim();
    if (text.isEmpty || text.length > maxLength) return null;
    // An address is the one kind that spans lines.
    if (text.contains('\n')) return _address(text);
    // Coordinates, phone numbers and addresses are the kinds written with
    // spaces in them.
    if (text.contains(_whitespace)) {
      return _coordinates(text) ?? _phone(text) ?? _address(text);
    }

    final lower = text.toLowerCase();
    if (lower.startsWith('mailto:')) return _mailto(text);
    if (lower.startsWith('tel:')) {
      return _phone(Uri.decodeComponent(text.substring(4)), explicit: true);
    }
    if (lower.startsWith('geo:')) return _geo(text);
    if (lower.startsWith('http://') || lower.startsWith('https://')) {
      return _http(text);
    }
    if (lower.startsWith('www.')) return _http('https://$text');
    if (_email.hasMatch(text)) {
      return ClipLink._(
        ClipLinkKind.email,
        Uri(scheme: 'mailto', path: text),
        text,
      );
    }
    return _coordinates(text) ??
        _tracking(text) ??
        _appLink(text) ??
        _localAddress(text) ??
        _phone(text);
  }

  static ClipLink? _http(String text) {
    final uri = Uri.tryParse(text);
    if (uri == null || !uri.hasAuthority) return null;
    final host = uri.host.toLowerCase();
    if (host.isEmpty || !(host.contains('.') || host == 'localhost')) {
      return null;
    }
    final place = _MapPlace.fromWeb(uri);
    if (place != null) {
      return ClipLink._(ClipLinkKind.map, uri, place.label);
    }
    final site = host.startsWith('www.') ? host.substring(4) : host;
    for (final (kind, services) in _webServices) {
      for (final (name, matches) in services) {
        if (matches(site, uri)) {
          return ClipLink._(kind, uri, name, service: name);
        }
      }
    }
    return ClipLink._(ClipLinkKind.web, uri, site);
  }

  static final _meetCode = RegExp('^/[a-z]{3}-[a-z]{4}-[a-z]{3}');
  static final _amazonMusic = RegExp(r'^music\.amazon\.[a-z.]+$');

  static bool _hostIs(String host, String domain) =>
      host == domain || host.endsWith('.$domain');

  static bool _pathStarts(Uri uri, String prefix) =>
      uri.path.toLowerCase().startsWith(prefix);

  /// Web links that belong to a service with an app of its own, by kind.
  /// Checked in order, so YouTube Music is music before YouTube is video.
  static final List<
    (ClipLinkKind, List<(String, bool Function(String host, Uri uri))>)
  >
  _webServices = [
    (
      ClipLinkKind.meeting,
      [
        (
          'Zoom',
          (h, u) =>
              _hostIs(h, 'zoom.us') &&
              (_pathStarts(u, '/j/') ||
                  _pathStarts(u, '/my/') ||
                  _pathStarts(u, '/w/') ||
                  _pathStarts(u, '/s/')),
        ),
        (
          'Google Meet',
          (h, u) => h == 'meet.google.com' && _meetCode.hasMatch(u.path),
        ),
        (
          'Microsoft Teams',
          (h, u) =>
              (h == 'teams.microsoft.com' &&
                  u.path.contains('/l/meetup-join')) ||
              (h == 'teams.live.com' && _pathStarts(u, '/meet')),
        ),
        (
          'Webex',
          (h, u) =>
              _hostIs(h, 'webex.com') &&
              (u.path.contains('/meet/') ||
                  u.path.contains('/join/') ||
                  u.path.contains('j.php')),
        ),
        ('FaceTime', (h, u) => h == 'facetime.apple.com'),
        ('Whereby', (h, u) => h == 'whereby.com' && u.path.length > 1),
      ],
    ),
    (
      ClipLinkKind.music,
      [
        ('Spotify', (h, u) => h == 'open.spotify.com' || h == 'spotify.link'),
        ('Apple Music', (h, u) => h == 'music.apple.com'),
        ('Apple Podcasts', (h, u) => h == 'podcasts.apple.com'),
        ('YouTube Music', (h, u) => h == 'music.youtube.com'),
        ('SoundCloud', (h, u) => _hostIs(h, 'soundcloud.com')),
        ('TIDAL', (h, u) => h == 'tidal.com' || h == 'listen.tidal.com'),
        (
          'Deezer',
          (h, u) => _hostIs(h, 'deezer.com') || h == 'deezer.page.link',
        ),
        ('Amazon Music', (h, u) => _amazonMusic.hasMatch(h)),
        ('Bandcamp', (h, u) => _hostIs(h, 'bandcamp.com')),
        ('Pandora', (h, u) => _hostIs(h, 'pandora.com')),
      ],
    ),
    (
      ClipLinkKind.video,
      [
        (
          'YouTube',
          (h, u) =>
              h == 'youtube.com' || h == 'm.youtube.com' || h == 'youtu.be',
        ),
        ('Vimeo', (h, u) => _hostIs(h, 'vimeo.com')),
        ('Twitch', (h, u) => _hostIs(h, 'twitch.tv')),
        ('TikTok', (h, u) => _hostIs(h, 'tiktok.com')),
      ],
    ),
  ];

  /// Custom-scheme links into apps, by scheme.
  ///
  /// An allowlist, never "any scheme": a clip is text from anywhere, and some
  /// schemes do far more than open an app - `javascript:`, `file:`,
  /// Android's `intent:`, and Windows protocol handlers like `ms-msdt:` that
  /// have been the way into remote-code exploits. These are apps that only
  /// navigate to something inside themselves.
  static const _appSchemes = <String, (ClipLinkKind, String)>{
    'zoommtg': (ClipLinkKind.meeting, 'Zoom'),
    'zoomus': (ClipLinkKind.meeting, 'Zoom'),
    'msteams': (ClipLinkKind.meeting, 'Microsoft Teams'),
    'facetime': (ClipLinkKind.meeting, 'FaceTime'),
    'spotify': (ClipLinkKind.music, 'Spotify'),
    'obsidian': (ClipLinkKind.app, 'Obsidian'),
    'notion': (ClipLinkKind.app, 'Notion'),
    'slack': (ClipLinkKind.app, 'Slack'),
    'discord': (ClipLinkKind.app, 'Discord'),
    'figma': (ClipLinkKind.app, 'Figma'),
    'vscode': (ClipLinkKind.app, 'VS Code'),
    'vscode-insiders': (ClipLinkKind.app, 'VS Code Insiders'),
    'cursor': (ClipLinkKind.app, 'Cursor'),
    'linear': (ClipLinkKind.app, 'Linear'),
    'steam': (ClipLinkKind.app, 'Steam'),
    'tg': (ClipLinkKind.app, 'Telegram'),
    'whatsapp': (ClipLinkKind.app, 'WhatsApp'),
    'sgnl': (ClipLinkKind.app, 'Signal'),
    'things': (ClipLinkKind.app, 'Things'),
    'todoist': (ClipLinkKind.app, 'Todoist'),
    'bear': (ClipLinkKind.app, 'Bear'),
    'craftdocs': (ClipLinkKind.app, 'Craft'),
    'drafts': (ClipLinkKind.app, 'Drafts'),
    'raycast': (ClipLinkKind.app, 'Raycast'),
    'shortcuts': (ClipLinkKind.app, 'Shortcuts'),
  };

  static ClipLink? _appLink(String text) {
    final colon = text.indexOf(':');
    if (colon <= 0) return null;
    final scheme = text.substring(0, colon).toLowerCase();
    final app = _appSchemes[scheme];
    if (app == null) return null;
    final uri = Uri.tryParse(text);
    if (uri == null || text.length == colon + 1) return null;
    final (kind, name) = app;
    // spotify:track:<id> is also https://open.spotify.com/track/<id>, which
    // opens the app where it is installed and the web player where it is not.
    if (scheme == 'spotify') {
      final parts = uri.path.split(':');
      if (parts.length == 2 && parts.every((p) => p.isNotEmpty)) {
        return ClipLink._(
          kind,
          Uri.https('open.spotify.com', '/${parts[0]}/${parts[1]}'),
          name,
          service: name,
        );
      }
    }
    return ClipLink._(kind, uri, name, service: name);
  }

  static final _localHost = RegExp(
    r'^(localhost|\d{1,3}(\.\d{1,3}){3}|[a-z0-9-]+(\.[a-z0-9-]+)*\.(local|lan|home|internal|home\.arpa))(:\d{1,5})?(/\S*)?$',
    caseSensitive: false,
  );
  static final _hostWithPort = RegExp(
    r'^[a-z0-9-]+(\.[a-z0-9-]+)+:\d{2,5}(/\S*)?$',
    caseSensitive: false,
  );

  /// A machine on the network, written without `http://`: `localhost:3000`,
  /// `192.168.1.1`, `printer.local`, `nas.lan:5000/admin`. Router pages and
  /// dev servers are copied like this, and only a browser opens them.
  static ClipLink? _localAddress(String text) {
    final match = _localHost.firstMatch(text);
    if (match == null && !_hostWithPort.hasMatch(text)) return null;
    if (match?.group(2) != null) {
      // An IPv4 address: four octets, each a byte.
      final octets = text.split(RegExp('[:/]')).first.split('.');
      if (octets.any((o) => int.parse(o) > 255)) return null;
    }
    final uri = Uri.tryParse('http://$text');
    if (uri == null || uri.host.isEmpty) return null;
    return ClipLink._(ClipLinkKind.web, uri, uri.host);
  }

  static final _decimalCoordinates = RegExp(
    r'^(-?\d{1,2}\.\d{3,})\s*,\s*(-?\d{1,3}\.\d{3,})$',
  );
  static final _dmsCoordinates = RegExp(
    r'''^(\d{1,2})°\s*(\d{1,2})['′]\s*(\d{1,2}(?:\.\d+)?)["″]\s*([NS])[\s,]+(\d{1,3})°\s*(\d{1,2})['′]\s*(\d{1,2}(?:\.\d+)?)["″]\s*([EW])$''',
    caseSensitive: false,
  );

  /// Coordinates as maps apps copy them: `43.64263, -79.38712` (Google Maps'
  /// right-click) or `43°38'33.5"N 79°23'13.6"W` (its place card). At least
  /// three decimals each, so a pair of ordinary numbers is not a place.
  static ClipLink? _coordinates(String text) {
    double? lat;
    double? lng;
    final decimal = _decimalCoordinates.firstMatch(text);
    if (decimal != null) {
      lat = double.parse(decimal.group(1)!);
      lng = double.parse(decimal.group(2)!);
    } else if (_dmsCoordinates.firstMatch(text) case final dms?) {
      double degrees(int at) =>
          double.parse(dms.group(at)!) +
          double.parse(dms.group(at + 1)!) / 60 +
          double.parse(dms.group(at + 2)!) / 3600;
      lat = degrees(1) * (dms.group(4)!.toUpperCase() == 'S' ? -1 : 1);
      lng = degrees(5) * (dms.group(8)!.toUpperCase() == 'W' ? -1 : 1);
    }
    if (lat == null || lng == null || lat.abs() > 90 || lng.abs() > 180) {
      return null;
    }
    String fixed(double v) =>
        v.toStringAsFixed(6).replaceFirst(RegExp(r'\.?0+$'), '');
    return ClipLink._(
      ClipLinkKind.map,
      Uri.parse('geo:${fixed(lat)},${fixed(lng)}'),
      text,
    );
  }

  static const _streetTypes =
      'St|Street|Ave|Avenue|Rd|Road|Blvd|Boulevard|Dr|Drive|Ln|Lane|Way|'
      'Ct|Court|Pl|Place|Pkwy|Parkway|Hwy|Highway|Cres|Crescent|Ter|Terrace|'
      'Cir|Circle|Sq|Square|Trl|Trail|Row|Close|Gardens|Mews|Grove|Line|'
      'Sideroad|Concession|Gate|Heights|Hill|Park';
  static final _streetLine = RegExp(
    r'^(?:(?:unit|suite|apt|#)\s*\w+[,\s]+)?\d+[a-z]?(?:-\d+)?\s+'
    r"(?:[a-z0-9][\w'.-]*\s+){0,4}(?:"
    '$_streetTypes'
    r')\.?(?:\s+(?:N|S|E|W|NE|NW|SE|SW|North|South|East|West))?'
    r'(?:$|[,\n]|\s+(?:unit|suite|apt|#))',
    caseSensitive: false,
  );
  static final _frenchStreet = RegExp(
    r'^\d+[a-z]?,?\s+(?:rue|avenue|av\.?|boulevard|boul\.?|chemin|ch\.?|route|rang|mont[ée]e|place|all[ée]e|impasse|quai|cours)\s+\S',
    caseSensitive: false,
  );
  static final _continentalStreet = RegExp(
    r"^[\wÀ-ÿ'.-]+(?:stra(?:ß|ss)e|str\.|weg|platz|allee|gasse|laan|straat|gatan|vej|veien)\s+\d+[a-z]?(?:$|[,\n])",
    caseSensitive: false,
  );
  static final _postalCode = RegExp(
    // Canada, UK, then a US state and ZIP.
    r'\b([A-Z]\d[A-Z] ?\d[A-Z]\d|[A-Z]{1,2}\d[A-Z\d]? ?\d[A-Z]{2}|[A-Z]{2},? \d{5}(?:-\d{4})?)\b',
  );

  /// A street address, on one line or up to four: `123 Main St`,
  /// `1600 Amphitheatre Pkwy, Mountain View, CA 94043`, `350 rue Sherbrooke`,
  /// `Unter den Linden 77`, `221B Baker Street\nLondon NW1 6XE`.
  ///
  /// A best guess, and deliberately one that leans towards yes: the cost of a
  /// wrong one is an Open in Maps button on a clip that did not need it. The
  /// first line has to read as a street - a house number and a street type
  /// (St, Ave, rue, Straße...) - or start with a number and be followed by a
  /// postal code. Anything with an `@` or `://` in it is something else.
  static ClipLink? _address(String text) {
    if (text.length > 300 || text.contains('@') || text.contains('://')) {
      return null;
    }
    final lines = [
      for (final line in text.split('\n'))
        if (line.trim().isNotEmpty) line.trim(),
    ];
    if (lines.isEmpty || lines.length > 4) return null;
    if (lines.any((line) => line.length > 120)) return null;
    final first = lines.first;
    final joined = lines.join(', ');
    final street =
        _streetLine.hasMatch(joined) ||
        _frenchStreet.hasMatch(first) ||
        _continentalStreet.hasMatch(joined);
    final numbered =
        RegExp(r'^\d+[a-z]?\b', caseSensitive: false).hasMatch(first) &&
        _postalCode.hasMatch(joined);
    if (!street && !numbered) return null;
    return ClipLink._(
      ClipLinkKind.map,
      Uri(scheme: 'geo', path: '0,0', queryParameters: {'q': joined}),
      first,
    );
  }

  static final _ups = RegExp(r'^1Z[0-9A-Z]{16}$');
  static final _usps = RegExp(r'^9[2-5]\d{18,20}$');
  static final _s10 = RegExp(r'^[A-Z]{2}\d{9}[A-Z]{2}$');

  /// A parcel tracking number, as the carrier's own tracking page.
  ///
  /// Only formats that cannot be mistaken for something else: UPS's `1Z`
  /// numbers and the international postal format (`LM123456789CA`), both
  /// checked against their check digit, and USPS's 20-22 digit numbers, which
  /// start 92-95. FedEx and DHL numbers are plain runs of 10-15 digits, the
  /// same as order numbers and codes, so they stay text.
  static ClipLink? _tracking(String text) {
    final number = text.toUpperCase();
    if (_ups.hasMatch(number) && _upsCheckDigitOk(number)) {
      return ClipLink._parcel(
        'UPS',
        Uri.https('www.ups.com', '/track', {'tracknum': number}),
        number,
      );
    }
    if (_usps.hasMatch(number)) {
      return ClipLink._parcel('USPS', _uspsPage(number), number);
    }
    if (_s10.hasMatch(number) && _s10CheckDigitOk(number)) {
      return switch (number.substring(11)) {
        'CA' => ClipLink._parcel(
          'Canada Post',
          Uri.parse(
            'https://www.canadapost-postescanada.ca/track-reperage/en#/search?searchFor=$number',
          ),
          number,
        ),
        'US' => ClipLink._parcel('USPS', _uspsPage(number), number),
        'GB' => ClipLink._parcel(
          'Royal Mail',
          Uri.parse(
            'https://www.royalmail.com/track-your-item#/tracking-results/$number',
          ),
          number,
        ),
        'AU' => ClipLink._parcel(
          'Australia Post',
          Uri.https('auspost.com.au', '/mypost/track/details/$number'),
          number,
        ),
        // Every other postal service: a tracker that knows them all.
        _ => ClipLink._parcel(
          'Post',
          Uri.parse('https://t.17track.net/en#nums=$number'),
          number,
        ),
      };
    }
    return null;
  }

  static Uri _uspsPage(String number) => Uri.https(
    'tools.usps.com',
    '/go/TrackConfirmAction',
    {'tLabels': number},
  );

  /// UPS: the 15 characters after `1Z`, letters as `(code - 63) % 10`, odd
  /// places once and even places twice; the last digit brings it to a ten.
  static bool _upsCheckDigitOk(String number) {
    var sum = 0;
    for (var i = 2; i < 17; i++) {
      final c = number.codeUnitAt(i);
      final value = c >= 48 && c <= 57 ? c - 48 : (c - 63) % 10;
      sum += (i - 2).isEven ? value : value * 2;
    }
    return (10 - sum % 10) % 10 == number.codeUnitAt(17) - 48;
  }

  /// UPU S10: weights 8 6 4 2 3 5 9 7 over the serial, eleven minus the sum
  /// mod 11, with 10 written 0 and 11 written 5.
  static bool _s10CheckDigitOk(String number) {
    const weights = [8, 6, 4, 2, 3, 5, 9, 7];
    var sum = 0;
    for (var i = 0; i < 8; i++) {
      sum += (number.codeUnitAt(2 + i) - 48) * weights[i];
    }
    final check = switch (11 - sum % 11) {
      10 => 0,
      11 => 5,
      final digit => digit,
    };
    return check == number.codeUnitAt(10) - 48;
  }

  static ClipLink? _mailto(String text) {
    final uri = Uri.tryParse(text);
    if (uri == null) return null;
    final address = Uri.decodeComponent(uri.path);
    if (!_email.hasMatch(address)) return null;
    return ClipLink._(ClipLinkKind.email, uri, address);
  }

  static ClipLink? _geo(String text) {
    final uri = Uri.tryParse(text);
    if (uri == null) return null;
    final place = _MapPlace.fromGeo(uri);
    if (place == null) return null;
    return ClipLink._(ClipLinkKind.map, uri, place.label);
  }

  /// A phone number, written the way people write them.
  ///
  /// Deliberately narrow, because a false positive puts a Call button on a
  /// clip that is not a phone number. A bare run of digits is skipped - one-
  /// time codes, order numbers and account numbers all look like that, and
  /// someone copying a real number from a contact or a web page gets it
  /// formatted. So a number has to start with `+` or carry the brackets,
  /// dashes, dots or spaces a number is written with, and dates and IP
  /// addresses, which have the same characters, are ruled out. A `tel:` link
  /// says what it is, so [explicit] lifts the formatting requirement.
  static ClipLink? _phone(String text, {bool explicit = false}) {
    final number = text.trim();
    if (!_phoneChars.hasMatch(number)) return null;
    if (_ipv4.hasMatch(number) || _date.hasMatch(number)) return null;
    final digits = number.replaceAll(_nonDigit, '');
    if (digits.length < 7 || digits.length > 15) return null;
    final international = number.startsWith('+');
    if (!explicit && !international && digits.length == number.length) {
      return null;
    }
    final dialled = international ? '+$digits' : digits;
    return ClipLink._(
      ClipLinkKind.phone,
      Uri(scheme: 'tel', path: dialled),
      number,
    );
  }

  /// The URI to hand to the operating system on [platform], a
  /// `device_type_enum` value.
  ///
  /// Web, email and phone links open as they are. Map links are rewritten
  /// where the platform's maps app will not answer the link as sent:
  ///
  /// - Android: an Apple Maps or `geo:` link becomes `geo:`, which every maps
  ///   app on Android registers for. Apple Maps has no Android app, and its
  ///   web version does not run in a phone browser. Google Maps links already
  ///   open in the Google Maps app.
  /// - macOS: an Apple Maps link in the classic `?q=&ll=` form becomes the
  ///   same query on `maps:`, which opens the Maps app; as `https:` it goes to
  ///   the default browser. The newer `/place`, `/search` and `/directions`
  ///   forms carry ids `maps:` has no parameter for, so they open as sent.
  /// - iOS: a `geo:` link, which iOS does not handle, becomes an Apple Maps
  ///   link. Apple Maps links already open the Maps app.
  /// - Windows, Linux: a `geo:` link, which neither handles, becomes a Google
  ///   Maps search, which opens in any browser.
  ///
  /// A short link (`maps.apple/p/...`, `maps.app.goo.gl/...`) carries no
  /// place to rewrite, so it opens as sent and the browser follows it.
  Uri openUri(String platform) {
    if (kind != ClipLinkKind.map) return uri;
    final place = uri.scheme == 'geo'
        ? _MapPlace.fromGeo(uri)
        : _MapPlace.fromWeb(uri);
    if (place == null) return uri;
    final apple = place.source == _MapSource.apple;
    final geo = place.source == _MapSource.geo;

    switch (platform) {
      case 'android':
        if ((apple || geo) && place.hasLocation) return place.toGeo();
      case 'macos':
        if (apple &&
            !place.isShortLink &&
            (uri.path.isEmpty || uri.path == '/')) {
          return Uri.parse('maps://?${uri.query}');
        }
        if (geo) return place.toAppleMaps(scheme: 'maps');
      case 'ios':
        if (geo) return place.toAppleMaps(scheme: 'https');
      case 'windows':
      case 'linux':
        if (geo) return place.toGoogleMaps();
    }
    return uri;
  }

  /// Whether [platform] has anything that opens this kind of link.
  ///
  /// Linux has no standard handler for `tel:` - xdg-open hands it to the
  /// browser, which does nothing useful with it. Windows has Phone Link and
  /// macOS has FaceTime, both of which place the call on a paired phone.
  bool canOpenOn(String platform) =>
      !(kind == ClipLinkKind.phone && platform == 'linux');

  /// The second thing to do with it, if there is one:
  ///
  /// - A phone number can be texted as well as called (`sms:`; Messages on
  ///   a Mac, Phone Link on Windows).
  /// - A song or album can be found on the other services through song.link,
  ///   which is what makes an Apple Music link useful on a phone with only
  ///   Spotify, and the other way round.
  ClipLinkAlternate? get alternate => switch (kind) {
    ClipLinkKind.phone => ClipLinkAlternate(
      'Text',
      Uri(scheme: 'sms', path: uri.path),
    ),
    ClipLinkKind.music => ClipLinkAlternate(
      'Find on other services',
      Uri.parse('https://song.link/$uri'),
    ),
    _ => null,
  };

  /// Whether [platform] can do [alternate]: no texting from Linux either.
  bool canAlternateOn(String platform) =>
      alternate != null && !(kind == ClipLinkKind.phone && platform == 'linux');

  /// What the button that opens it says.
  String get actionLabel => switch (kind) {
    ClipLinkKind.web => 'Open link',
    ClipLinkKind.map => 'Open in Maps',
    ClipLinkKind.email => 'Write email',
    ClipLinkKind.phone => 'Call',
    ClipLinkKind.meeting => 'Join meeting',
    ClipLinkKind.music => 'Open in $service',
    ClipLinkKind.video => 'Watch on $service',
    ClipLinkKind.tracking => 'Track package',
    ClipLinkKind.app => 'Open in $service',
  };

  /// A short noun for the kind, for the meta line and screen readers.
  String get kindLabel => switch (kind) {
    ClipLinkKind.web => 'Link',
    ClipLinkKind.map => 'Map',
    ClipLinkKind.email => 'Email',
    ClipLinkKind.phone => 'Phone',
    ClipLinkKind.meeting => 'Meeting',
    ClipLinkKind.music => 'Music',
    ClipLinkKind.video => 'Video',
    ClipLinkKind.tracking => 'Package',
    ClipLinkKind.app => 'App link',
  };
}

enum _MapSource { apple, google, geo }

/// A place pulled out of a map link: a search text, a coordinate, or both.
class _MapPlace {
  const _MapPlace(
    this.source, {
    this.query,
    this.latLng,
    this.isShortLink = false,
  });

  final _MapSource source;
  final String? query;

  /// `lat,lng`, as both Apple's `ll` and `geo:` write it.
  final String? latLng;

  /// `maps.apple/p/...` or `maps.app.goo.gl/...`: only the redirect knows the
  /// place.
  final bool isShortLink;

  bool get hasLocation => query != null || latLng != null;

  String get label =>
      query ??
      latLng ??
      switch (source) {
        _MapSource.apple => 'Apple Maps',
        _MapSource.google => 'Google Maps',
        _MapSource.geo => 'Location',
      };

  static const _googleShortHosts = {'maps.app.goo.gl', 'goo.gl'};
  static final _googleHost = RegExp(r'^(www\.)?google\.[a-z.]+$');

  static _MapPlace? fromWeb(Uri uri) {
    final host = uri.host.toLowerCase();
    final params = uri.queryParameters;

    if (host == 'maps.apple.com') {
      return _MapPlace(
        _MapSource.apple,
        // The classic parameters and the 2024 /place, /search and
        // /directions ones.
        query: _first(params, const [
          'name',
          'q',
          'query',
          'address',
          'destination',
          'daddr',
          'saddr',
        ]),
        latLng: _latLngOrNull(
          params['ll'] ?? params['coordinate'] ?? params['sll'],
        ),
      );
    }
    if (host == 'maps.apple') {
      return const _MapPlace(_MapSource.apple, isShortLink: true);
    }

    final segments = uri.pathSegments;
    if (_googleShortHosts.contains(host)) {
      if (host == 'goo.gl' && (segments.isEmpty || segments.first != 'maps')) {
        return null;
      }
      return const _MapPlace(_MapSource.google, isShortLink: true);
    }
    final googleHost = host == 'maps.google.com' || _googleHost.hasMatch(host);
    if (!googleHost) return null;
    if (host != 'maps.google.com' &&
        (segments.isEmpty || segments.first != 'maps')) {
      return null;
    }

    // /maps/place/<name>/@lat,lng,zoom and /maps/search/<query>
    var query = _first(params, const ['q', 'query', 'destination']);
    String? latLng;
    for (var i = 0; i < segments.length; i++) {
      final segment = segments[i];
      if ((segment == 'place' || segment == 'search') &&
          i + 1 < segments.length &&
          !segments[i + 1].startsWith('@')) {
        query ??= segments[i + 1].replaceAll('+', ' ');
      } else if (segment.startsWith('@')) {
        final parts = segment.substring(1).split(',');
        if (parts.length >= 2) {
          latLng = _latLngOrNull('${parts[0]},${parts[1]}');
        }
      }
    }
    if (query != null && _latLngOrNull(query) != null) {
      latLng ??= _latLngOrNull(query);
      query = null;
    }
    return _MapPlace(_MapSource.google, query: query, latLng: latLng);
  }

  /// `geo:lat,lng`, `geo:lat,lng?q=...`, `geo:0,0?q=...`.
  static _MapPlace? fromGeo(Uri uri) {
    final coords = uri.path.split(';').first;
    final latLng = _latLngOrNull(coords);
    final query = uri.queryParameters['q'];
    final hasQuery = query != null && query.trim().isNotEmpty;
    // geo:0,0 is the "no coordinate, search instead" form.
    final realLatLng = latLng == '0,0' ? null : latLng;
    if (realLatLng == null && !hasQuery) return null;
    return _MapPlace(
      _MapSource.geo,
      query: hasQuery ? query.trim() : null,
      latLng: realLatLng,
    );
  }

  static String? _first(Map<String, String> params, List<String> keys) {
    for (final key in keys) {
      final value = params[key]?.trim();
      if (value != null && value.isNotEmpty) return value;
    }
    return null;
  }

  static String? _latLngOrNull(String? value) {
    final trimmed = value?.replaceAll(' ', '');
    if (trimmed == null || !ClipLink._latLng.hasMatch(trimmed)) return null;
    return trimmed;
  }

  Uri toGeo() => Uri.parse(
    'geo:${latLng ?? '0,0'}'
    '${query != null ? '?q=${Uri.encodeQueryComponent(query!)}' : ''}',
  );

  Uri toAppleMaps({required String scheme}) {
    final params = Uri(
      queryParameters: {
        if (query != null) 'q': query,
        if (latLng != null) 'll': latLng,
      },
    ).query;
    return Uri.parse(
      scheme == 'https' ? 'https://maps.apple.com/?$params' : 'maps://?$params',
    );
  }

  Uri toGoogleMaps() => Uri.https('www.google.com', '/maps/search/', {
    'api': '1',
    'query': query ?? latLng!,
  });
}
