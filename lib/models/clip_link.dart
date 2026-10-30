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
    if (text.isEmpty || text.length > maxLength || text.contains('\n')) {
      return null;
    }
    // Phone numbers are the only kind written with spaces in them.
    if (text.contains(_whitespace)) return _phone(text);

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
    return _phone(text);
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
    return ClipLink._(ClipLinkKind.web, uri, site);
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
