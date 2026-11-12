import 'dart:math' as math;

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
    r'''^[A-Za-z0-9!#$%&'*+/=?^_`{|}~-]+(?:\.[A-Za-z0-9!#$%&'*+/=?^_`{|}~-]+)*@'''
    r'(?:[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?\.)+'
    r'(?:[A-Za-z]{2,}|xn--[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?)$',
  );
  static final _phoneChars = RegExp(r'^\+?[0-9()\-. ]+$');
  static final _explicitPhoneChars = RegExp(r'^\+?[0-9A-Fa-f*#()\-. ]+$');
  static final _phoneSeparators = RegExp(r'[()\-. ]');
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
  static final _isbn10Format = RegExp(r'^\d+[- ]\d+[- ]\d+[- ]\d$');
  // A US ZIP+4 code (`94043-1351`), as copied from an address form.
  static final _zipPlus4 = RegExp(r'^\d{5}-\d{4}$');
  // A decimal (`3.14159265`, `12345.67`) or a number grouped in thousands
  // with dots (`1.000.000`, `12.345.678`): one dot, or a short lead group
  // followed only by groups of three, which no dotted phone number is.
  // Not a local number written 3.4 (`555.1234`), which is one dot too.
  static final _decimalNumber = RegExp(
    r'^(?!\d{3}\.\d{4}$)\d+\.\d+$|^\d{1,2}(\.\d{3}){2,}$',
  );
  static final _latLng = RegExp(r'^-?\d+(\.\d+)?,-?\d+(\.\d+)?$');
  // Dot-separated labels, none empty: `intranet`, `example.com`, `münchen.de`.
  static final _hostLabels = RegExp(r'^[^.\s]+(\.[^.\s]+)*$');
  // A domestic trunk prefix written in brackets after a country code
  // (`+44 (0)20 7946 0958`), which is never dialled internationally.
  static final _bracketedTrunkZero = RegExp(r'\(\s*0\s*\)');

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
    // Phone numbers are the only kind written with spaces in them - and a
    // `tel:` href as a page wrote it, spaced for reading
    // (`tel:+1 416 555 0199`): not a valid URI, but plainly a number.
    final lower = text.toLowerCase();
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
      final parameters = path.substring(separator);
      if (number == null || parameters.contains(_whitespace)) return null;
      return ClipLink._(
        ClipLinkKind.phone,
        path.contains(_whitespace)
            ? uri.replace(path: '${number.uri.path}$parameters')
            : uri,
        number.label,
      );
    }
    if (text.contains(_whitespace)) return _phone(text);
    if (lower.startsWith('mailto:')) return _mailto(text);
    if (lower.startsWith('geo:')) return _geo(text);
    if (lower.startsWith('http://') || lower.startsWith('https://')) {
      return _http(text);
    }
    if (lower.startsWith('www.')) return _http('https://$text');
    if (_email.hasMatch(text)) {
      return ClipLink._(
        ClipLinkKind.email,
        Uri.parse('mailto:${Uri.encodeComponent(text).replaceAll('%40', '@')}'),
        text,
      );
    }
    return _phone(text);
  }

  static ClipLink? _http(String text) {
    final uri = Uri.tryParse(text);
    if (uri == null || !uri.hasAuthority) return null;
    final host = uri.host.toLowerCase();
    // Only reached with an explicit http(s) scheme (or `www.`), so any
    // syntactically valid host counts, a single label included:
    // `https://intranet/wiki` or `http://router/status` resolve through
    // local DNS or a search domain, and RFC 3986 leaves that to the OS. An
    // IPv6 literal (`[2001:db8::1]`) arrives without its brackets.
    // A trailing dot (`example.com.`) is a fully qualified name, but the dot
    // has to separate labels: `www.` alone, or `.com`, is not a site.
    final name = host.endsWith('.') ? host.substring(0, host.length - 1) : host;
    final validHost =
        host.contains(':') ||
        (_hostLabels.hasMatch(name) &&
            (!host.endsWith('.') || name.contains('.')));
    if (!validHost) return null;
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
    if (!(explicit ? _explicitPhoneChars : _phoneChars).hasMatch(number)) {
      return null;
    }
    // Service symbols and hexadecimal identifiers belong to local plans;
    // a global (+) telephone number still contains decimal digits only.
    if (number.startsWith('+') && !_phoneChars.hasMatch(number)) return null;
    // No number is written with a leading minus: that is a negative
    // quantity or a longitude (`-122.4194`).
    if (!explicit &&
        (number.startsWith('-') ||
            _ipv4.hasMatch(number) ||
            _date.hasMatch(number) ||
            _ssn.hasMatch(number))) {
      return null;
    }
    // ITU-T E.123: the trunk 0 after a country code is shown in brackets
    // for domestic callers and dropped when dialling internationally.
    final dialable = number.startsWith('+')
        ? number.replaceAll(_bracketedTrunkZero, '')
        : number;
    final digits = dialable.replaceAll(_nonDigit, '');
    final identifier = dialable.replaceAll(_phoneSeparators, '');
    if (identifier.replaceFirst('+', '').isEmpty ||
        (!explicit && (digits.length < 7 || digits.length > 15))) {
      return null;
    }
    final international = number.startsWith('+');
    if (!explicit && !international) {
      if (digits.length == number.length) return null;
      // A payment card number written in groups (`3782 822463 10005`, an
      // American Express number) has the characters of a phone number too;
      // the card's Luhn check digit tells it apart. Only from 13 digits up,
      // where cards start and national phone numbers have mostly stopped.
      if (digits.length >= 13 && _luhnValid(digits)) return null;
      // An ISBN-13 (`978-0-306-40615-7`) is a dashed run of 13 digits too.
      if (digits.length == 13 &&
          (digits.startsWith('978') || digits.startsWith('979'))) {
        return null;
      }
      // ISBN-10 has four groups and a modulo-11 check digit. Keep ordinary
      // phone grouping, explicit tel: links and international numbers.
      if (digits.length == 10 &&
          _isbn10Format.hasMatch(number) &&
          _isbn10Valid(digits)) {
        return null;
      }
      // So is a range (`1000-2000`): two long groups and a dash. A number
      // written that way starts with a trunk 0 (`0800-123456`).
      if (_range.hasMatch(number)) return null;
      if (_zipPlus4.hasMatch(number) || _decimalNumber.hasMatch(number)) {
        return null;
      }
    }
    final dialled = explicit
        ? identifier
        : (international ? '+$digits' : digits);
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
          // Problem reports and future Apple workflows must retain their action.
          if (!const {
            '',
            '/',
            '/place',
            '/search',
            '/frame',
            '/directions',
            '/look-around',
          }.contains(uri.path)) {
            return uri;
          }
          // Rewrite only options whose meaning we preserve. Apple place IDs
          // cannot be translated into Google IDs, and frame/view options
          // must not silently become an ordinary pin.
          final supportedParameters = switch (uri.path) {
            '/frame' => const {'center', 'coordinate'},
            '/look-around' => const {'coordinate', 'll'},
            _ => const {
              'q',
              'query',
              'name',
              'address',
              'll',
              'coordinate',
              'center',
              'sll',
              'saddr',
              'source',
              'daddr',
              'destination',
              'dirflg',
              'mode',
              'waypoint',
              'avoid',
            },
          };
          if (uri.hasFragment ||
              uri.queryParameters.keys.any(
                (key) => !supportedParameters.contains(key),
              )) {
            return uri;
          }
          final avoid = (uri.queryParametersAll['avoid'] ?? const <String>[])
              .expand((value) => value.split(','))
              .map((value) => value.trim());
          if (avoid.any(
            (value) =>
                value.isNotEmpty &&
                !const {'tolls', 'highways'}.contains(value),
          )) {
            return uri;
          }
          if (uri.path == '/look-around') {
            // Preserve the panorama intent. Apple-only place IDs and
            // addresses cannot supply a Street View viewpoint.
            final coordinates = place.latLng;
            if (coordinates == null) return uri;
            return Uri.https('www.google.com', '/maps/@', {
              'api': '1',
              'map_action': 'pano',
              'viewpoint': coordinates,
            });
          }
          if (_appleDirections(uri) case final directions?) return directions;
          if (place.hasLocation) return place.toGeo();
        }
      // geo: as sent: Android handles it, zoom (?z=) and uncertainty
      // (;u=) included, which a rebuilt URI would drop.
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
    final waypoints = (uri.queryParametersAll['waypoint'] ?? const <String>[])
        .map((value) => value.trim())
        .where((value) => value.isNotEmpty)
        .toList();
    // Apple repeats waypoint parameters; Google joins them with pipes.
    // Only tolls and highways are avoid preferences shared by both formats.
    final avoid = (uri.queryParametersAll['avoid'] ?? const <String>[])
        .expand((value) => value.split(','))
        .map((value) => value.trim())
        .where((value) => const {'tolls', 'highways'}.contains(value))
        .toSet();
    return Uri.https('www.google.com', '/maps/dir/', {
      'api': '1',
      if (!fromHere) 'origin': origin,
      'destination': destination,
      'travelmode': ?mode,
      if (waypoints.isNotEmpty) 'waypoints': waypoints.join('|'),
      if (avoid.isNotEmpty) 'avoid': avoid.join(','),
    });
  }

  static bool _isbn10Valid(String digits) {
    var sum = 0;
    for (var i = 0; i < digits.length; i++) {
      sum += (digits.codeUnitAt(i) - 48) * (10 - i);
    }
    return sum % 11 == 0;
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
    this.zoom,
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

  /// Android geo zoom, from world (0) to buildings (21).
  final int? zoom;

  /// `maps.apple/p/...` or `maps.app.goo.gl/...`: only the redirect knows the
  /// place.
  final bool isShortLink;

  bool get hasLocation => query != null || latLng != null || center != null;

  String get label =>
      query ??
      latLng ??
      center ??
      switch (source) {
        _MapSource.apple => 'Apple Maps',
        _MapSource.google => 'Google Maps',
        _MapSource.geo => 'Location',
      };

  static const _googleShortHosts = {'maps.app.goo.gl', 'goo.gl'};
  // Explicit Google-owned country domains, rather than guessed suffixes.
  // Source: https://www.google.com/supported_domains (2026-11-12).
  static const _googleDomains = {
    'google.ad',
    'google.ae',
    'google.al',
    'google.am',
    'google.as',
    'google.at',
    'google.az',
    'google.ba',
    'google.be',
    'google.bf',
    'google.bg',
    'google.bi',
    'google.bj',
    'google.bs',
    'google.bt',
    'google.by',
    'google.ca',
    'google.cat',
    'google.cd',
    'google.cf',
    'google.cg',
    'google.ch',
    'google.ci',
    'google.cl',
    'google.cm',
    'google.cn',
    'google.co.ao',
    'google.co.bw',
    'google.co.ck',
    'google.co.cr',
    'google.co.id',
    'google.co.il',
    'google.co.in',
    'google.co.jp',
    'google.co.ke',
    'google.co.kr',
    'google.co.ls',
    'google.co.ma',
    'google.co.mz',
    'google.co.nz',
    'google.co.th',
    'google.co.tz',
    'google.co.ug',
    'google.co.uk',
    'google.co.uz',
    'google.co.ve',
    'google.co.vi',
    'google.co.za',
    'google.co.zm',
    'google.co.zw',
    'google.com',
    'google.com.af',
    'google.com.ag',
    'google.com.ar',
    'google.com.au',
    'google.com.bd',
    'google.com.bh',
    'google.com.bn',
    'google.com.bo',
    'google.com.br',
    'google.com.bz',
    'google.com.co',
    'google.com.cu',
    'google.com.cy',
    'google.com.do',
    'google.com.ec',
    'google.com.eg',
    'google.com.et',
    'google.com.fj',
    'google.com.gh',
    'google.com.gi',
    'google.com.gt',
    'google.com.hk',
    'google.com.jm',
    'google.com.kh',
    'google.com.kw',
    'google.com.lb',
    'google.com.ly',
    'google.com.mm',
    'google.com.mt',
    'google.com.mx',
    'google.com.my',
    'google.com.na',
    'google.com.ng',
    'google.com.ni',
    'google.com.np',
    'google.com.om',
    'google.com.pa',
    'google.com.pe',
    'google.com.pg',
    'google.com.ph',
    'google.com.pk',
    'google.com.pr',
    'google.com.py',
    'google.com.qa',
    'google.com.sa',
    'google.com.sb',
    'google.com.sg',
    'google.com.sl',
    'google.com.sv',
    'google.com.tj',
    'google.com.tr',
    'google.com.tw',
    'google.com.ua',
    'google.com.uy',
    'google.com.vc',
    'google.com.vn',
    'google.cv',
    'google.cz',
    'google.de',
    'google.dj',
    'google.dk',
    'google.dm',
    'google.dz',
    'google.ee',
    'google.es',
    'google.fi',
    'google.fm',
    'google.fr',
    'google.ga',
    'google.ge',
    'google.gg',
    'google.gl',
    'google.gm',
    'google.gr',
    'google.gy',
    'google.hn',
    'google.hr',
    'google.ht',
    'google.hu',
    'google.ie',
    'google.im',
    'google.iq',
    'google.is',
    'google.it',
    'google.je',
    'google.jo',
    'google.kg',
    'google.ki',
    'google.kz',
    'google.la',
    'google.li',
    'google.lk',
    'google.lt',
    'google.lu',
    'google.lv',
    'google.md',
    'google.me',
    'google.mg',
    'google.mk',
    'google.ml',
    'google.mn',
    'google.mu',
    'google.mv',
    'google.mw',
    'google.ne',
    'google.nl',
    'google.no',
    'google.nr',
    'google.nu',
    'google.pl',
    'google.pn',
    'google.ps',
    'google.pt',
    'google.ro',
    'google.rs',
    'google.ru',
    'google.rw',
    'google.sc',
    'google.se',
    'google.sh',
    'google.si',
    'google.sk',
    'google.sm',
    'google.sn',
    'google.so',
    'google.sr',
    'google.st',
    'google.td',
    'google.tg',
    'google.tl',
    'google.tm',
    'google.tn',
    'google.to',
    'google.tt',
    'google.vu',
    'google.ws',
  };

  static bool _isGoogleHost(String host) {
    final domain = host.startsWith('www.')
        ? host.substring(4)
        : host.startsWith('maps.')
        ? host.substring(5)
        : host;
    return _googleDomains.contains(domain);
  }

  static _MapPlace? fromWeb(Uri uri) {
    final rawHost = uri.host.toLowerCase();
    final host = rawHost.endsWith('.')
        ? rawHost.substring(0, rawHost.length - 1)
        : rawHost;
    // Query parameters are read only once the host is a maps one: every web
    // link passes through here.
    if (host == 'maps.apple.com') {
      final params = uri.queryParameters;
      final latLng = _latLngOrNull(params['ll'] ?? params['coordinate']);
      // On a /place link `address` is where the place is and `name` only
      // what its card is called. Without coordinates the name alone would
      // search for any business of that name, so keep the address with it.
      final name = params['name']?.trim();
      final address = params['address']?.trim();
      final namedAddress =
          latLng == null &&
              name != null &&
              name.isNotEmpty &&
              address != null &&
              address.isNotEmpty
          ? '$name, $address'
          : null;
      return _MapPlace(
        _MapSource.apple,
        // The classic parameters and the 2024 /place, /search and
        // /directions ones.
        query:
            namedAddress ??
            _first(params, const [
              'name',
              'q',
              'query',
              'address',
              'destination',
              'daddr',
              'saddr',
            ]),
        latLng: latLng,
        center: _latLngOrNull(params['center'] ?? params['sll']),
      );
    }
    if (host == 'maps.apple') {
      return const _MapPlace(_MapSource.apple, isShortLink: true);
    }

    final segments = uri.pathSegments;
    if (_googleShortHosts.contains(host)) {
      if (host == 'goo.gl' && segments.firstOrNull != 'maps') {
        return null;
      }
      return const _MapPlace(_MapSource.google, isShortLink: true);
    }
    if (!_isGoogleHost(host)) return null;
    if (!host.startsWith('maps.') && segments.firstOrNull != 'maps') {
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
    final components = uri.path.split(';');
    for (final parameter in components.skip(1)) {
      final separator = parameter.indexOf('=');
      if (separator < 0) continue;
      final name = parameter.substring(0, separator).toLowerCase();
      final value = parameter.substring(separator + 1).toLowerCase();
      if (name == 'crs' && value != 'wgs84') return null;
    }
    var coords = components.first;
    final parts = coords.split(',');
    if (parts.length == 3 && _number.hasMatch(parts[2].trim())) {
      coords = '${parts[0]},${parts[1]}';
    }
    final latLng = _latLngOrNull(coords);
    if (latLng == null) return null;
    final requestedZoom = int.tryParse(uri.queryParameters['z'] ?? '');
    final zoom =
        requestedZoom != null && requestedZoom >= 0 && requestedZoom <= 21
        ? requestedZoom
        : null;
    final query = uri.queryParameters['q']?.trim();
    // Android's q=lat,lng(label) selects a pin independently of the geo:
    // path, which may be 0,0 or the map's search center.
    final labelStart = query?.indexOf('(') ?? -1;
    if (query != null && labelStart > 0 && query.endsWith(')')) {
      final pin = _latLngOrNull(query.substring(0, labelStart));
      if (pin != null) {
        final label = query.substring(labelStart + 1, query.length - 1).trim();
        return _MapPlace(
          _MapSource.geo,
          query: label.isEmpty ? null : label,
          latLng: pin,
          zoom: zoom,
        );
      }
    }
    final hasQuery = query != null && query.isNotEmpty;
    // A numeric q identifies its own pin; the geo path only biases a
    // textual search. Signed and decimal zeroes all mean an unscoped search.
    if (_latLngOrNull(query) case final pin?) {
      return _MapPlace(_MapSource.geo, latLng: pin, zoom: zoom);
    }
    final zero = latLng.split(',').every((part) => double.parse(part) == 0);
    final location = zero ? null : latLng;
    if (location == null && !hasQuery) return null;
    return _MapPlace(
      _MapSource.geo,
      query: hasQuery ? query : null,
      latLng: hasQuery ? null : location,
      center: hasQuery ? location : null,
      zoom: zoom,
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
    final components = trimmed.split(',').map(double.parse).toList();
    if (components[0].abs() > 90 || components[1].abs() > 180) return null;
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
  /// `maps:` otherwise, which only the Maps app does. Nearby searches use
  /// the unified web route on both platforms to preserve their search center.
  Uri toAppleMaps({required bool web}) {
    if (query != null && (center != null || zoom != null)) {
      return Uri.https('maps.apple.com', '/search', {
        'query': query,
        'center': ?center,
        if (zoom != null) 'span': _searchSpan,
      });
    }
    final params = Uri(
      queryParameters: {
        if (query != null) 'q': query,
        if (latLng != null) 'll': latLng,
        if (zoom != null) 'z': zoom.toString(),
      },
    ).query;
    return Uri.parse(
      web ? 'https://maps.apple.com/?$params' : 'maps://?$params',
    );
  }

  // Apple search uses an angular span rather than a numeric zoom. Approximate
  // a Web Mercator tile's bounds at this latitude; the app chooses its viewport.
  String get _searchSpan {
    final longitude = 360 / math.pow(2, zoom!);
    final latitude = double.parse((center ?? '0,0').split(',').first);
    final latitudeSpan = (longitude * math.cos(latitude * math.pi / 180)).clamp(
      0.0000001,
      180,
    );
    return '${latitudeSpan.toStringAsFixed(7)},${longitude.toStringAsFixed(7)}';
  }

  /// A pin, or a search.
  ///
  /// A pin at [latLng] stays a pin at those coordinates even when it has a
  /// label: Google Maps URLs cannot carry a label, and searching for it - a
  /// `geo:` `(Treasure)`, Apple's `q` beside `ll` - could find another place
  /// or nothing. A search for [query] near [center] is scoped to it, in the
  /// form Google Maps writes its own links in: the API form has no way to
  /// say where to search, and `query=Home` alone could find any Home.
  Uri toGoogleMaps() {
    final pin = latLng;
    if (pin != null) {
      if (zoom != null) {
        return Uri(
          scheme: 'https',
          host: 'www.google.com',
          pathSegments: ['maps', 'place', pin, '@$pin,${zoom}z'],
        );
      }
      return Uri.https('www.google.com', '/maps/search/', {
        'api': '1',
        'query': pin,
      });
    }
    if (query != null && center != null) {
      return Uri(
        scheme: 'https',
        host: 'www.google.com',
        pathSegments: ['maps', 'search', query!, '@$center,${zoom ?? 15}z'],
      );
    }
    if (center != null && zoom != null) {
      return Uri(
        scheme: 'https',
        host: 'www.google.com',
        pathSegments: ['maps', 'place', center!, '@$center,${zoom}z'],
      );
    }
    return Uri.https('www.google.com', '/maps/search/', {
      'api': '1',
      'query': query ?? center!,
    });
  }
}
