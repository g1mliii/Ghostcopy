/// What kind of openable thing a clip is.
enum ClipLinkKind { web, map, email, phone }

/// A text clip that is, in its entirety, something the receiving device can
/// open: a web page, a place, an email address or a phone number.
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
  const ClipLink._(this.kind, this.uri, this.label);

  final ClipLinkKind kind;

  /// The link as sent, with a scheme added where the clip had none
  /// (`www.example.com`, a bare address, a formatted phone number).
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
    // The last label is letters, or punycode for a non-Latin top-level
    // domain (`xn--p1ai`).
    r'^[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*'
    r'\.([A-Za-z]{2,}|xn--[A-Za-z0-9-]+)$',
  );
  static final _phoneChars = RegExp(r'^\+?[0-9()\-. ]+$');
  // No-break and narrow no-break spaces: what a number copied from a web
  // page, PDF or document is often spaced with (`+33 1 42 68 53 00`).
  static final _noBreakSpace = RegExp('[\u00A0\u202F]');
  static final _nonDigit = RegExp(r'\D');
  static final _ipv4 = RegExp(r'^\d{1,3}(\.\d{1,3}){3}$');
  static final _date = RegExp(
    r'^(\d{4}[-./]\d{1,2}[-./]\d{1,2}|\d{1,2}[-./]\d{1,2}[-./]\d{2,4})$',
  );
  // Round on both ends, as ranges are written (`1000-2000`): a phone number
  // with two four-digit groups (`2123-4567`, a Hong Kong number) is not.
  static final _range = RegExp(r'^[1-9]\d+00-[1-9]\d+00$');
  // A US Social Security number. No phone numbering plan is written 3-2-4.
  static final _ssn = RegExp(r'^\d{3}-\d{2}-\d{4}$');
  static final _latLng = RegExp(r'^-?\d+(\.\d+)?,-?\d+(\.\d+)?$');

  /// The link this clip is, or null when it is not one.
  ///
  /// Never throws: it runs while a history row builds, so one synced clip
  /// that cannot be decoded - `tel:%FF`, an escape that is not UTF-8 - would
  /// otherwise replace that row with an error on every device. Such a clip
  /// stays text.
  static ClipLink? detect(String content) {
    try {
      return _detect(content);
    } on FormatException {
      return null;
    }
  }

  static ClipLink? _detect(String content) {
    final text = content.trim();
    if (text.isEmpty || text.length > maxLength || text.contains('\n')) {
      return null;
    }
    // Phone numbers are the only kind written with spaces in them.
    if (text.contains(_whitespace)) return _phone(text);

    final lower = text.toLowerCase();
    if (lower.startsWith('mailto:')) return _mailto(text);
    if (lower.startsWith('tel:')) {
      // Through Uri, which turns a stray `%` into `%25`, rather than
      // decoding the raw text: Uri.decodeComponent throws an ArgumentError on
      // `tel:%` or `tel:%zz`, and detect runs while a history row builds.
      final uri = Uri.tryParse(text);
      if (uri == null || uri.hasQuery || uri.hasFragment) return null;
      // RFC 3966 parameters - `;ext=456`, `;phone-context=...` - follow the
      // number. The number alone is checked; the link keeps them.
      final path = Uri.decodeComponent(uri.path);
      final separator = path.indexOf(';');
      if (separator < 0) return _phone(path, explicit: true);
      final number = _phone(path.substring(0, separator), explicit: true);
      if (number == null || path.contains(_whitespace)) return null;
      return ClipLink._(ClipLinkKind.phone, uri, number.label);
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
    return _phone(text);
  }

  static ClipLink? _http(String text) {
    final uri = Uri.tryParse(text);
    if (uri == null || !uri.hasAuthority) return null;
    final host = uri.host.toLowerCase();
    // A name with a dot, localhost, or an IPv6 literal (`[2001:db8::1]`,
    // which Uri.host gives without its brackets).
    final validHost =
        host.contains('.') || host == 'localhost' || host.contains(':');
    if (host.isEmpty || !validHost) return null;
    final place = _MapPlace.fromWeb(uri);
    if (place != null) {
      return ClipLink._(ClipLinkKind.map, uri, place.label);
    }
    final site = host.startsWith('www.') ? host.substring(4) : host;
    return ClipLink._(ClipLinkKind.web, uri, site);
  }

  static ClipLink? _mailto(String text) {
    final uri = Uri.tryParse(text);
    if (uri == null) return null;
    final address = Uri.decodeComponent(uri.path);
    // Recipients are optional: `mailto:?subject=Feedback` opens a draft to
    // be addressed. A link with neither is just the scheme, and stays text.
    if (address.trim().isEmpty) {
      if (uri.query.isEmpty) return null;
      return ClipLink._(ClipLinkKind.email, uri, 'New email');
    }
    // A mailto: link may name several recipients, comma-separated; each has
    // to be an address, and the link keeps them all.
    final recipients = address.split(',').map((a) => a.trim()).toList();
    if (recipients.any((a) => !_email.hasMatch(a))) return null;
    return ClipLink._(ClipLinkKind.email, uri, recipients.join(', '));
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
    final number = text.trim().replaceAll(_noBreakSpace, ' ');
    if (!_phoneChars.hasMatch(number)) return null;
    if (_ipv4.hasMatch(number) ||
        _date.hasMatch(number) ||
        _ssn.hasMatch(number)) {
      return null;
    }
    final digits = number.replaceAll(_nonDigit, '');
    if (digits.length < 7 || digits.length > 15) return null;
    // A payment card number written in groups (`3782 822463 10005`, an
    // American Express number) has the characters of a phone number too; the
    // card's Luhn check digit tells it apart. Only from 13 digits up, where
    // cards start and national phone numbers have mostly stopped.
    if (!explicit &&
        !number.startsWith('+') &&
        digits.length >= 13 &&
        _luhnValid(digits)) {
      return null;
    }
    final international = number.startsWith('+');
    if (!explicit && !international) {
      if (digits.length == number.length) return null;
      // An ISBN-13 (`978-0-306-40615-7`) is a dashed run of 13 digits too.
      if (digits.length == 13 &&
          (digits.startsWith('978') || digits.startsWith('979'))) {
        return null;
      }
      // So is a range (`1000-2000`): two long groups and a dash. A number
      // written that way starts with a trunk 0 (`0800-123456`).
      if (_range.hasMatch(number)) return null;
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
        if (apple) {
          if (_appleDirections(uri) case final directions?) return directions;
        }
        // geo: as sent: Android handles it, zoom (?z=) and uncertainty
        // (;u=) included, which a rebuilt URI would drop.
        if (apple && place.hasLocation) return place.toGeo();
      case 'macos':
        if (apple &&
            !place.isShortLink &&
            (uri.path.isEmpty || uri.path == '/')) {
          return Uri.parse('maps://?${uri.query}');
        }
        if (geo) return place.toAppleMaps(web: false);
      case 'ios':
        if (geo) return place.toAppleMaps(web: true);
      case 'windows':
      case 'linux':
        if (geo) return place.toGoogleMaps();
    }
    return uri;
  }

  /// An Apple Maps directions link as the same route in Google Maps, which
  /// Android's maps app opens: `geo:` holds only a place, so a route rewritten
  /// to it lost its start and travel mode and was no longer directions.
  static Uri? _appleDirections(Uri uri) {
    final params = uri.queryParameters;
    final destination = params['daddr'] ?? params['destination'];
    if (destination == null || destination.trim().isEmpty) return null;
    final origin = params['saddr'] ?? params['source'];
    // Apple's word for "from where I am", which is also Google's default.
    final fromHere =
        origin == null ||
        origin.trim().isEmpty ||
        origin.trim().toLowerCase() == 'current location';
    final mode = switch (params['dirflg'] ?? params['mode']) {
      'd' || 'driving' => 'driving',
      'w' || 'walking' => 'walking',
      'r' || 'transit' => 'transit',
      'cycling' => 'bicycling',
      _ => null,
    };
    return Uri.https('www.google.com', '/maps/dir/', {
      'api': '1',
      if (!fromHere) 'origin': origin,
      'destination': destination,
      'travelmode': ?mode,
    });
  }

  static bool _luhnValid(String digits) {
    var sum = 0;
    for (var i = 0; i < digits.length; i++) {
      var digit = digits.codeUnitAt(digits.length - 1 - i) - 48;
      if (i.isOdd) {
        digit *= 2;
        if (digit > 9) digit -= 9;
      }
      sum += digit;
    }
    return sum % 10 == 0;
  }

  /// Whether [platform] has anything that opens this kind of link.
  ///
  /// Linux has no standard handler for `tel:` - xdg-open hands it to the
  /// browser, which does nothing useful with it. Windows has Phone Link and
  /// macOS has FaceTime, both of which place the call on a paired phone.
  bool canOpenOn(String platform) =>
      !(kind == ClipLinkKind.phone && platform == 'linux');

  /// What the button that opens it says.
  String get actionLabel => switch (kind) {
    ClipLinkKind.web => 'Open link',
    ClipLinkKind.map => 'Open in Maps',
    ClipLinkKind.email => 'Write email',
    ClipLinkKind.phone => 'Call',
  };

  /// A short noun for the kind, for the meta line and screen readers.
  String get kindLabel => switch (kind) {
    ClipLinkKind.web => 'Link',
    ClipLinkKind.map => 'Map',
    ClipLinkKind.email => 'Email',
    ClipLinkKind.phone => 'Phone',
  };
}

enum _MapSource { apple, google, geo }

/// A place pulled out of a map link: a search text, a coordinate, or both.
class _MapPlace {
  const _MapPlace(
    this.source, {
    this.query,
    this.latLng,
    this.center,
    this.isShortLink = false,
  });

  final _MapSource source;
  final String? query;

  /// `lat,lng`, as both Apple's `ll` and `geo:` write it.
  final String? latLng;

  /// Where a search is centred, not a place: Apple's classic `sll` or
  /// `center` on a `/search` link. A pin at [latLng] is labelled with [query];
  /// a search for [query] near [center] finds whatever is there.
  final String? center;

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
  // google.com and Google's country domains (google.ca, google.co.uk,
  // google.com.au) - not any host that starts google., which
  // google.com.evil does.
  static final _googleHost = RegExp(
    r'^(www\.)?google\.(com|[a-z]{2}|co\.[a-z]{2}|com\.[a-z]{2})$',
  );

  static _MapPlace? fromWeb(Uri uri) {
    final host = uri.host.toLowerCase();
    // Query parameters are read only once the host is a maps one: every web
    // link passes through here.
    if (host == 'maps.apple.com') {
      final params = uri.queryParameters;
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
        latLng: _latLngOrNull(params['ll'] ?? params['coordinate']),
        center: _latLngOrNull(params['center'] ?? params['sll']),
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
    var query = _first(uri.queryParameters, const [
      'q',
      'query',
      'destination',
    ]);
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
    if (query != null) {
      if (_latLngOrNull(query) case final coordinates?) {
        latLng ??= coordinates;
        query = null;
      }
    }
    return _MapPlace(_MapSource.google, query: query, latLng: latLng);
  }

  /// `geo:lat,lng`, `geo:lat,lng?q=...`, `geo:0,0?q=...`, and the 3D
  /// `geo:lat,lng,alt`, whose altitude no map here uses.
  static _MapPlace? fromGeo(Uri uri) {
    var coords = uri.path.split(';').first;
    final parts = coords.split(',');
    if (parts.length == 3 && _number.hasMatch(parts[2].trim())) {
      coords = '${parts[0]},${parts[1]}';
    }
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

  static final _number = RegExp(r'^-?\d+(\.\d+)?$');

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

  Uri toGeo() {
    // A textual q searches near the coordinates. Android's lat,lng(label)
    // form keeps the selected pin and uses the place name only as its label.
    // A search keeps its centre as the place to search near.
    final geoQuery = query == null
        ? null
        : latLng == null
        ? query
        : '$latLng($query)';
    return Uri.parse(
      'geo:${latLng ?? center ?? '0,0'}'
      '${geoQuery != null ? '?q=${Uri.encodeQueryComponent(geoQuery)}' : ''}',
    );
  }

  /// On maps.apple.com when [web], which every Apple device answers; on
  /// `maps:` otherwise, which only the Maps app does.
  Uri toAppleMaps({required bool web}) {
    final params = Uri(
      queryParameters: {
        if (query != null) 'q': query,
        if (latLng != null) 'll': latLng,
      },
    ).query;
    return Uri.parse(
      web ? 'https://maps.apple.com/?$params' : 'maps://?$params',
    );
  }

  /// A search, or a pin. With both a query and coordinates the search is
  /// scoped to them, in the form Google Maps writes its own links in: the
  /// API form has no way to say where to search, and `query=Home` alone
  /// could find any Home.
  Uri toGoogleMaps() {
    final near = latLng ?? center;
    if (query != null && near != null) {
      return Uri(
        scheme: 'https',
        host: 'www.google.com',
        pathSegments: ['maps', 'search', query!, '@$near,15z'],
      );
    }
    return Uri.https('www.google.com', '/maps/search/', {
      'api': '1',
      'query': query ?? latLng!,
    });
  }
}
