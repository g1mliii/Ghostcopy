import '../utils/ip_address.dart';

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

/// Which second thing a [ClipLinkAlternate] does.
enum ClipLinkAlternateKind { text, findElsewhere }

/// A second thing to do with a link, beside opening it: text a phone number,
/// find a song on another service.
class ClipLinkAlternate {
  const ClipLinkAlternate(this.kind, this.label, this.uri);

  final ClipLinkAlternateKind kind;
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
    // The last label is letters, or punycode for a non-Latin top-level
    // domain (`xn--p1ai`).
    r'^[A-Za-z0-9_%+-]+(?:\.[A-Za-z0-9_%+-]+)*@'
    r'(?:[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?\.)+'
    r'(?:[A-Za-z]{2,}|xn--[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?)$',
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
    if (text.isEmpty || text.length > maxLength) return null;
    // Addresses, and tracking numbers printed in groups, are the kinds that
    // can span lines.
    if (text.contains('\n')) return _address(text) ?? _groupedTracking(text);
    // Coordinates, phone numbers and addresses are the kinds written with
    // spaces in them - and tracking numbers, which carriers print in groups
    // (`RR 123 456 785 CA`, `1Z 999 AA1 01 2345 678 4`) - and a `tel:` href
    // as a page wrote it, spaced for reading (`tel:+1 416 555 0199`): not a
    // valid URI, but plainly a number.
    final lower = text.toLowerCase();
    if (text.contains(_whitespace)) {
      if (lower.startsWith('tel:')) {
        return _phone(text.substring(4), explicit: true);
      }
      return _coordinates(text) ??
          _phone(text) ??
          _address(text) ??
          _groupedTracking(text);
    }

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
    // A name with a dot, localhost, or an IPv6 literal (`[2001:db8::1]`,
    // which Uri.host gives without its brackets).
    // A trailing dot (`example.com.`) is a fully qualified name, but the dot
    // has to separate labels: `www.` alone, or `.com`, is not a site.
    final name = host.endsWith('.') ? host.substring(0, host.length - 1) : host;
    final validHost =
        (name.contains('.') && !name.startsWith('.')) ||
        host == 'localhost' ||
        host.contains(':');
    if (!validHost) return null;
    final place = _MapPlace.fromWeb(uri);
    if (place != null) {
      return ClipLink._(ClipLinkKind.map, uri, place.label);
    }
    final site = host.startsWith('www.') ? host.substring(4) : host;
    // A music service's home page is a page, not something to play or find
    // elsewhere: song.link has nothing to resolve for `open.spotify.com/`.
    final hasPath = uri.pathSegments.any((s) => s.isNotEmpty);
    for (final (kind, name, matches) in _webServices) {
      // Nor is a video site's: youtube.com/ is not something to watch.
      // Nor are its help, developer and company sites (help.twitch.tv,
      // artists.spotify.com), which are pages about the service.
      if ((kind == ClipLinkKind.music || kind == ClipLinkKind.video) &&
          (!hasPath || _aboutSite.hasMatch(site))) {
        continue;
      }
      if (matches(site, uri)) return ClipLink._(kind, uri, name, service: name);
    }
    return ClipLink._(ClipLinkKind.web, uri, site);
  }

  // A meeting code, or Classroom's stable /lookup/<id> link to a class's
  // current meeting.
  static final _meetCode = RegExp(
    r'^/([a-z]{3}-[a-z]{4}-[a-z]{3}|lookup/\w+)/?$',
  );
  // Amazon's own storefront domains, not any suffix after `amazon.`
  // (`music.amazon.attacker.com`).
  static final _amazonMusic = RegExp(
    r'^music\.amazon\.(com|ca|de|fr|it|es|in|co\.uk|co\.jp|com\.au|com\.br|com\.mx)$',
  );

  static final _aboutSite = RegExp(
    '^(help|support|developers?|docs|blog|status|community|press|newsroom|'
    r'investors?|careers|jobs|artists|creators|partners|ads|business|api)\.',
  );

  static bool _hostIs(String host, String domain) =>
      host == domain || host.endsWith('.$domain');

  /// [uri]'s path segments without the empty ones a trailing (or doubled)
  /// slash leaves: `/room/` is `[room]`.
  static List<String> _segments(Uri uri) => [
    for (final s in uri.pathSegments)
      if (s.isNotEmpty) s,
  ];

  /// A Teams invitation in its older form: `/l/meetup-join/<id>`.
  static bool _teamsInvite(Uri uri) => switch (uri.pathSegments) {
    ['l', final route, final id, ...] =>
      route.toLowerCase() == 'meetup-join' && id.isNotEmpty,
    _ => false,
  };

  /// A Webex invitation: `<site>/j.php?MTID=...`, or a personal room at
  /// `/meet/<name>` or `/join/<name>`.
  static bool _webexMeeting(Uri uri) {
    final s = [for (final p in uri.pathSegments) p.toLowerCase()];
    for (var i = 0; i < s.length; i++) {
      if (s[i] == 'j.php') {
        return (uri.queryParameters['MTID'] ?? '').isNotEmpty;
      }
      if ((s[i] == 'meet' || s[i] == 'join') &&
          i + 1 < s.length &&
          s[i + 1].isNotEmpty) {
        return true;
      }
    }
    return false;
  }

  /// Whether [uri]'s path is [route] and then an id: `/meet/<id>`, not a
  /// bare `/meet/`.
  static bool _idAfter(Uri uri, String route) => switch (uri.pathSegments) {
    [final r, final id, ...] => r.toLowerCase() == route && id.isNotEmpty,
    _ => false,
  };

  /// Web links that belong to a service with an app of its own. Checked in
  /// order, so YouTube Music is music before YouTube is video.
  static final List<(ClipLinkKind, String, bool Function(String host, Uri uri))>
  _webServices = [
    (
      ClipLinkKind.meeting,
      'Zoom',
      (h, u) =>
          // Zoom, and Zoom for Government.
          (_hostIs(h, 'zoom.us') || _hostIs(h, 'zoomgov.com')) &&
          switch ([for (final s in u.pathSegments) s.toLowerCase()]) {
            ['j' || 'my' || 'w' || 's', final id, ...] => id.isNotEmpty,
            // The Zoom Web App: /wc/<meeting>/join.
            ['wc', final id, ..., 'join'] => id.isNotEmpty,
            _ => false,
          },
    ),
    (
      ClipLinkKind.meeting,
      'Google Meet',
      (h, u) => h == 'meet.google.com' && _meetCode.hasMatch(u.path),
    ),
    (
      ClipLinkKind.meeting,
      'Microsoft Teams',
      (h, u) =>
          (h == 'teams.microsoft.com' &&
              // Older invitations, and the shorter /meet/<id>?p=... ones
              // new meetings get.
              (_teamsInvite(u) || _idAfter(u, 'meet'))) ||
          (h == 'teams.live.com' && _idAfter(u, 'meet')) ||
          // US government clouds: GCC High and DoD.
          ((h == 'gov.teams.microsoft.us' || h == 'dod.teams.microsoft.us') &&
              _teamsInvite(u)),
    ),
    (
      ClipLinkKind.meeting,
      'Webex',
      (h, u) => _hostIs(h, 'webex.com') && _webexMeeting(u),
    ),
    // An invitation, not the FaceTime site itself.
    (
      ClipLinkKind.meeting,
      'FaceTime',
      (h, u) =>
          h == 'facetime.apple.com' &&
          // The invitation itself rides in the fragment: /join#v=1&p=...
          u.fragment.isNotEmpty &&
          switch (_segments(u)) {
            [final only] => only.toLowerCase() == 'join',
            _ => false,
          },
    ),
    (
      ClipLinkKind.meeting,
      'Whereby',
      // whereby.com, or a Business account's own subdomain
      // (company.whereby.com) - not Whereby's own help and docs sites.
      (h, u) =>
          _hostIs(h, 'whereby.com') &&
          !_wherebySites.contains(h) &&
          switch (_segments(u)) {
            [final room] => !_wherebyPages.contains(room.toLowerCase()),
            _ => false,
          },
    ),
    (
      ClipLinkKind.music,
      'Spotify',
      (h, u) => h == 'open.spotify.com' || h == 'spotify.link',
    ),
    (
      ClipLinkKind.music,
      'Apple Music',
      (h, u) => h == 'music.apple.com' || h == 'classical.music.apple.com',
    ),
    (ClipLinkKind.music, 'Apple Podcasts', (h, u) => h == 'podcasts.apple.com'),
    (ClipLinkKind.music, 'YouTube Music', (h, u) => h == 'music.youtube.com'),
    (ClipLinkKind.music, 'SoundCloud', (h, u) => _hostIs(h, 'soundcloud.com')),
    (
      ClipLinkKind.music,
      'TIDAL',
      (h, u) => h == 'tidal.com' || h == 'listen.tidal.com',
    ),
    (
      ClipLinkKind.music,
      'Deezer',
      (h, u) => _hostIs(h, 'deezer.com') || h == 'deezer.page.link',
    ),
    (ClipLinkKind.music, 'Amazon Music', (h, u) => _amazonMusic.hasMatch(h)),
    (ClipLinkKind.music, 'Bandcamp', (h, u) => _hostIs(h, 'bandcamp.com')),
    (
      ClipLinkKind.music,
      'Pandora',
      // pandora.app.link is where the app's Copy Link points.
      (h, u) => _hostIs(h, 'pandora.com') || h == 'pandora.app.link',
    ),
    (
      ClipLinkKind.video,
      'YouTube',
      (h, u) => h == 'youtube.com' || h == 'm.youtube.com' || h == 'youtu.be',
    ),
    (ClipLinkKind.video, 'Vimeo', (h, u) => _hostIs(h, 'vimeo.com')),
    (ClipLinkKind.video, 'Twitch', (h, u) => _hostIs(h, 'twitch.tv')),
    (ClipLinkKind.video, 'TikTok', (h, u) => _hostIs(h, 'tiktok.com')),
  ];

  /// Custom-scheme links into apps, by scheme.
  ///
  /// An allowlist, never "any scheme": a clip is text from anywhere, and some
  /// schemes do far more than open an app - `javascript:`, `file:`,
  /// Android's `intent:`, and Windows protocol handlers like `ms-msdt:` that
  /// have been the way into remote-code exploits. These are apps that only
  /// navigate to something inside themselves.
  ///
  /// Left out for doing more than that in one tap: `shortcuts:` runs a
  /// shortcut, `steam:` installs and launches games, `raycast:` runs
  /// commands. VS Code and Cursor are in for `file` links only - opening a
  /// file at a line - since their other links hand the URI to extensions,
  /// which clone repositories and more ([_editorSchemes]). Note and to-do
  /// apps, Telegram (whose `tg://proxy` and `tg://socks` reconfigure the
  /// app's connection) and Signal (whose `sgnl://linkdevice` links another
  /// device to the account) are in for their navigation routes only
  /// ([_navigation]).
  static const _appSchemes = <String, (ClipLinkKind, String)>{
    'zoommtg': (ClipLinkKind.meeting, 'Zoom'),
    'zoomus': (ClipLinkKind.meeting, 'Zoom'),
    'msteams': (ClipLinkKind.meeting, 'Microsoft Teams'),
    'facetime': (ClipLinkKind.meeting, 'FaceTime'),
    'facetime-audio': (ClipLinkKind.meeting, 'FaceTime'),
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
    'tg': (ClipLinkKind.app, 'Telegram'),
    'whatsapp': (ClipLinkKind.app, 'WhatsApp'),
    'sgnl': (ClipLinkKind.app, 'Signal'),
    'things': (ClipLinkKind.app, 'Things'),
    'todoist': (ClipLinkKind.app, 'Todoist'),
    'bear': (ClipLinkKind.app, 'Bear'),
    'craftdocs': (ClipLinkKind.app, 'Craft'),
    'drafts': (ClipLinkKind.app, 'Drafts'),
  };

  static final _edgeSlashes = RegExp(r'^/+|/+$');

  static final _teamsMeetingPath = RegExp(
    '/l/(meetup-join|meeting|call)/[^/]',
    caseSensitive: false,
  );

  static const _wherebySites = {
    'support.whereby.com',
    'docs.whereby.com',
    'help.whereby.com',
    'blog.whereby.com',
    'status.whereby.com',
    'embedded.whereby.com',
  };

  /// Whereby's own site, beside its rooms (`whereby.com/<room>`).
  static const _wherebyPages = {
    'information',
    'user',
    'org',
    'login',
    'signup',
    'pricing',
    'blog',
    'careers',
    'download',
    'embedded',
    'about',
    'contact',
    'product',
    'features',
    'security',
    'terms',
    'privacy',
  };
  static const _editorSchemes = {'vscode', 'vscode-insiders', 'cursor'};

  /// Apps whose links also *do* things - run an action, add a task, trash a
  /// note - by route, and the routes that only open something. A link on
  /// any other route stays text. `drafts://x-callback-url/runAction` would
  /// otherwise run whatever that action does, from a synced clip.
  static const _navigation =
      <String, ({Set<String> routes, Set<String> params})>{
        'obsidian': (
          routes: {'open', 'search'},
          params: {'vault', 'file', 'path', 'query'},
        ),
        'drafts': (routes: {'open', 'x-callback-url/open'}, params: {'uuid'}),
        'bear': (
          routes: {
            'x-callback-url/open-note',
            'x-callback-url/open-tag',
            'x-callback-url/search',
          },
          params: {
            'id',
            'title',
            'header',
            'term',
            'name',
            'tag',
            'exclude_trashed',
            'new_window',
            'float',
            'show_window',
            'open_note',
          },
        ),
        'things': (
          routes: {'show', 'search'},
          params: {'id', 'query', 'filter'},
        ),
        'todoist': (
          routes: {'task', 'project', 'today', 'upcoming', 'inbox'},
          params: {'id'},
        ),
        'craftdocs': (routes: {'open'}, params: {'blockId', 'spaceId'}),
        'tg': (
          routes: {'resolve', 'privatepost', 'join'},
          params: {'domain', 'post', 'thread', 'comment', 'channel', 'invite'},
        ),
        // A chat, a group invite or a sticker pack, each confirmed in the
        // app - not `linkdevice`, which links another device to the account.
        'sgnl': (
          routes: {'signal.me', 'signal.group', 'addstickers'},
          params: {'pack_id', 'pack_key'},
        ),
      };

  static ClipLink? _appLink(String text) {
    final colon = text.indexOf(':');
    if (colon <= 0) return null;
    final scheme = text.substring(0, colon).toLowerCase();
    final app = _appSchemes[scheme];
    if (app == null) return null;
    final uri = Uri.tryParse(text);
    // A scheme with nothing after it (`zoommtg://`, `spotify:/`) opens
    // nothing.
    if (uri == null ||
        '${uri.host}${uri.path}'.replaceAll(_edgeSlashes, '').isEmpty) {
      return null;
    }
    if (_editorSchemes.contains(scheme) && uri.host != 'file') return null;
    if (_navigation[scheme] case (:final routes, params: final allowed)?) {
      final route = '${uri.host}${uri.path}'.toLowerCase().replaceAll(
        _edgeSlashes,
        '',
      );
      if (!routes.contains(route)) return null;
      // A navigation route can still be told to act - Drafts' `open` runs
      // `action=` on the draft it opens, Bear's `open-note` pins it with
      // `pin=yes`, and every x-callback-url route follows `x-success=` to
      // another URL. So only the parameters that say what to open are let
      // through.
      if (uri.queryParameters.keys.any((key) => !allowed.contains(key))) {
        return null;
      }
    }
    var (kind, name) = app;
    // Teams links go to chats, channels, files and tabs as well as meetings;
    // only a meeting or call link is joined.
    if (scheme == 'msteams' &&
        !_teamsMeetingPath.hasMatch('${uri.host}${uri.path}')) {
      kind = ClipLinkKind.app;
    }
    var target = uri;
    // spotify:track:<id> is also https://open.spotify.com/track/<id>, which
    // opens the app where it is installed and the web player where it is not.
    if (scheme == 'spotify') {
      final parts = uri.path.split(':');
      if (parts.length == 2 && parts.every((p) => p.isNotEmpty)) {
        target = Uri.https('open.spotify.com', '/${parts[0]}/${parts[1]}');
      }
    }
    return ClipLink._(kind, target, name, service: name);
  }

  static final _localHost = RegExp(
    r'^(localhost|\d{1,3}(\.\d{1,3}){3}|[a-z0-9-]+(\.[a-z0-9-]+)*\.(local|lan|home|internal|home\.arpa|localhost)|\[[0-9a-f:.]+\])(:\d{1,5})?([/?#]\S*)?$',
    caseSensitive: false,
  );
  // The top-level domain is a country code or a common generic one, so a
  // file and line with an extension outside [_fileAndLine]'s list
  // (`schema.sql:42`, `Component.vue:80`) does not read as a host. A country
  // code that is also an extension (`.rs`, `.py`, `.md`) is ruled out there.
  static final _hostWithPort = RegExp(
    r'^[a-z0-9-]+(\.[a-z0-9-]+)*'
    r'\.([a-z]{2}|com|org|net|edu|gov|mil|int|info|biz|dev|app|cloud|tech|'
    'site|online|xyz|page|run|live|host|systems|services|network|software)'
    r':\d{1,5}([/?#]\S*)?$',
    caseSensitive: false,
  );

  /// `main.dart:120`, `app.py:42`: a file and line, as compilers and stack
  /// traces write them, has the same shape as a host and port.
  static final _fileAndLine = RegExp(
    r'\.(dart|py|js|jsx|ts|tsx|mjs|cjs|kt|kts|java|swift|m|mm|c|cc|cpp|cxx|h|hh|hpp|cs|go|rs|rb|php|lua|sh|zig|scala|ex|exs|json|ya?ml|toml|xml|html?|css|scss|txt|md|log|'
    // Two-letter extensions, which [_hostWithPort] would otherwise read as
    // a country-code domain: Perl, OCaml, Terraform, Makefile fragments,
    // GDScript, Crystal, SystemVerilog, ReasonML, ActionScript, BitBake,
    // Apps Script, LiveScript, Nushell, Smalltalk, TableGen, Haskell, F#,
    // Julia, Visual Basic, Emacs Lisp, Haxe, Puppet, Verilog headers.
    r'pl|pm|ml|mk|tf|gd|cr|sv|re|as|bb|gs|ls|nu|st|td|hs|fs|jl|vb|el|hx|pp|vh):\d',
    caseSensitive: false,
  );

  /// A machine on the network, written without `http://`: `localhost:3000`,
  /// `192.168.1.1`, `printer.local`, `nas.lan:5000/admin`. Router pages and
  /// dev servers are copied like this, and only a browser opens them.
  ///
  /// A bare IPv4 address, with no port or path, only when it is a private
  /// one (a router, a NAS, this machine): `1.0.10.27` is as likely to be a
  /// four-part version number as an address, and a public server is not
  /// usually reached by typing its address into a browser.
  static ClipLink? _localAddress(String text) {
    final match = _localHost.firstMatch(text);
    if (match == null &&
        (!_hostWithPort.hasMatch(text) ||
            // Only the host and port can be a file and line: after them,
            // `/app.js:42` is plainly the URL's own path.
            _fileAndLine.hasMatch(text.split(_pathStart).first))) {
      return null;
    }
    if (match?.group(2) != null) {
      // An IPv4 address: four octets, each a byte.
      final address = match!.group(1)!;
      final octets = address.split('.').map(int.parse).toList();
      if (octets.any((o) => o > 255)) return null;
      // Bare, only a local machine. With a port or path, a public server
      // too - but never multicast, broadcast or the reserved blocks, which
      // serve no page either way.
      final bare = address.length == text.length;
      if (!isLocalUnicastIPv4(octets) && (bare || isNonPublicIPv4(octets))) {
        return null;
      }
    }
    final uri = Uri.tryParse('http://$text');
    if (uri == null || uri.host.isEmpty) return null;
    // A bracketed IPv6 address: never the unspecified `::` or multicast
    // (ff00::/8), which no browser opens a page on.
    if (uri.host.contains(':')) {
      final bytes = Uri.parseIPv6Address(uri.host.split('%').first);
      if (bytes[0] == 0xff || bytes.every((b) => b == 0)) return null;
      // Documentation: 2001:db8::/32 and 3fff::/20.
      if ((bytes[0] == 0x20 &&
              bytes[1] == 0x01 &&
              bytes[2] == 0x0d &&
              bytes[3] == 0xb8) ||
          (bytes[0] == 0x3f && bytes[1] == 0xff && bytes[2] < 0x10)) {
        return null;
      }
      // IPv4-mapped (::ffff:0:0/96): the IPv4 address's own rules.
      if (bytes.take(10).every((b) => b == 0) &&
          bytes[10] == 0xff &&
          bytes[11] == 0xff &&
          isNonPublicIPv4(bytes.sublist(12)) &&
          !isLocalUnicastIPv4(bytes.sublist(12))) {
        return null;
      }
    }
    // Five digits reach 99999; a port runs 1-65535, 0 being reserved.
    if (uri.hasPort && (uri.port < 1 || uri.port > 65535)) return null;
    // Port 443 is TLS: plain http to it fails.
    final target = uri.port == 443 ? uri.replace(scheme: 'https') : uri;
    return ClipLink._(ClipLinkKind.web, target, uri.host);
  }

  static final _trailingZeros = RegExp(r'\.?0+$');
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
      // Minutes and seconds run 0-59; `43°99'` is not a place.
      for (final at in [2, 3, 6, 7]) {
        if (double.parse(dms.group(at)!) >= 60) return null;
      }
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
    // `geo:0,0` means "no coordinate, search instead", and 0,0 is open sea:
    // a copied `0.000, 0.000` is a placeholder, not a place.
    if (lat == 0 && lng == 0) return null;
    String fixed(double v) =>
        v.toStringAsFixed(6).replaceFirst(_trailingZeros, '');
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
    // Street words may start with any letter: `123 Église St`. At least one,
    // and none of the little words a sentence is made of: `3 in a row`,
    // `2 for the road`, `1 more way` and `15 GB Drive` are not streets.
    '(?:(?!(?:a|an|in|on|at|of|for|to|and|or|more|per|by|is|are|was|my|'
    r"your|our|this|that|[kmgt]b)\s)[\p{L}0-9][\p{L}\p{N}_'.-]*\s+){1,4}(?:"
    '$_streetTypes'
    r')\.?(?:\s+(?:N|S|E|W|NE|NW|SE|SW|North|South|East|West))?'
    r'(?:$|[,\n]|\s+(?:unit|suite|apt|#))',
    caseSensitive: false,
    unicode: true,
  );
  static final _frenchStreet = RegExp(
    r'^\d+[a-z]?,?\s+(?:rue|avenue|av\.?|boulevard|boul\.?|chemin|ch\.?|route|rang|mont[ée]e|place|all[ée]e|impasse|quai|cours)\s+(\S+)',
    caseSensitive: false,
  );
  // What follows the street type in a French address: a name (`rue
  // Sherbrooke`), a number (`route 138`) or a particle (`rue de la Paix`) -
  // not an English word, as in `2 place settings` or `1 route change`.
  static final _frenchStreetName = RegExp(
    r"^(?:\p{Lu}|\d|(?:de|du|des|la|le|les)$|[ld]['’])",
    unicode: true,
  );
  static final _continentalStreet = RegExp(
    // Up to two words before the name that carries the type: `Alte
    // Dorfstraße 5`, `Am Alten Weg 3`.
    // The type is joined to the name (`Dorfstraße`) or, after at least one
    // other word, a word of its own (`Am Alten Weg`); alone, `Weg 3` is too
    // little to go on.
    r"^(?:(?:[\wÀ-ÿ'.-]+\s+){0,2}[\wÀ-ÿ'.-]+|(?:[\wÀ-ÿ'.-]+\s+){1,2})"
    r'(?:stra(?:ß|ss)e|str\.|weg|platz|allee|gasse|laan|straat|gatan|vej|veien)\s+\d+[a-z]?(?:-\d+)?(?:$|[,\n])',
    caseSensitive: false,
  );
  static final _houseNumber = RegExp(r'^\d+[a-z]?\b', caseSensitive: false);
  static final _postalCode = RegExp(
    // Canada, UK, then a US state and ZIP after the city's comma
    // (`Mountain View, CA 94043`): any two capitals and five digits would
    // also be `order ID 12345`.
    r'\b([A-Z]\d[A-Z] ?\d[A-Z]\d|[A-Z]{1,2}\d[A-Z\d]? ?\d[A-Z]{2})\b|'
    r',\s*[A-Z]{2},? \d{5}(?:-\d{4})?\b',
  );

  /// A street address, on one line or up to four: `123 Main St`,
  /// `1600 Amphitheatre Pkwy, Mountain View, CA 94043`, `350 rue Sherbrooke`,
  /// `Friedrichstraße 43`, `221B Baker Street\nLondon NW1 6XE`.
  ///
  /// A continental street needs its type in the name (-straße, -weg,
  /// -straat...). One without, like `Unter den Linden 77`, is words and then
  /// a number, which is also `Room 12` and `Chapter 3`, so it stays text.
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
        (_frenchStreet
                .firstMatch(first)
                ?.group(1)
                ?.contains(_frenchStreetName) ??
            false) ||
        _continentalStreet.hasMatch(joined);
    final numbered =
        _houseNumber.hasMatch(first) && _postalCode.hasMatch(joined);
    if (!street && !numbered) return null;
    return ClipLink._(
      ClipLinkKind.map,
      Uri(scheme: 'geo', path: '0,0', queryParameters: {'q': joined}),
      first,
    );
  }

  static final _ups = RegExp(r'^1Z[0-9A-Z]{16}$');
  static final _usps = RegExp(r'^9[2-5]\d{18,20}$');
  static final _groupedId = RegExp(r'^[A-Za-z0-9]+( [A-Za-z0-9]+)+$');
  static final _whitespaceRun = RegExp(r'\s+');

  /// A tracking number printed in groups, with whatever spacing it was
  /// copied with - no-break spaces from a PDF, doubled spaces.
  static ClipLink? _groupedTracking(String text) {
    final spaced = text.replaceAll(_whitespaceRun, ' ');
    if (!_groupedId.hasMatch(spaced)) return null;
    return _tracking(spaced.replaceAll(' ', ''));
  }

  static final _parcelforce = RegExp('^(E[A-E]|CP)');
  static final _s10 = RegExp(r'^[A-Z]{2}\d{9}[A-Z]{2}$');

  /// A parcel tracking number, as the carrier's own tracking page.
  ///
  /// Only formats that cannot be mistaken for something else: UPS's `1Z`
  /// numbers, the international postal format (`LM123456789CA`) and USPS's
  /// 20-22 digit numbers, which start 92-95, all checked against their check
  /// digit. FedEx and DHL numbers are plain runs of 10-15 digits, the
  /// same as order numbers and codes, so they stay text.
  static ClipLink? _tracking(String text) {
    // Every format below is 13-22 characters: skip upper-casing the rest.
    if (text.length < 13 || text.length > 22) return null;
    final number = text.toUpperCase();
    final (String, Uri)? parcel;
    if (_ups.hasMatch(number) && _upsCheckDigitOk(number)) {
      parcel = (
        'UPS',
        Uri.https('www.ups.com', '/track', {'tracknum': number}),
      );
    } else if (_usps.hasMatch(number) && _uspsCheckDigitOk(number)) {
      parcel = ('USPS', _uspsPage(number));
    } else if (_s10.hasMatch(number) && _s10CheckDigitOk(number)) {
      parcel = switch (number.substring(11)) {
        'CA' => (
          'Canada Post',
          Uri.parse(
            'https://www.canadapost-postescanada.ca/track-reperage/en#/search?searchFor=$number',
          ),
        ),
        'US' => ('USPS', _uspsPage(number)),
        // Parcelforce's services share Royal Mail's GB suffix, and Royal
        // Mail's tracker does not show them: EA-EE and CP.
        'GB' when _parcelforce.hasMatch(number) => (
          'Parcelforce',
          Uri.https('www.parcelforce.com', '/track-trace', {
            'trackNumber': number,
          }),
        ),
        'GB' => (
          'Royal Mail',
          Uri.parse(
            'https://www.royalmail.com/track-your-item#/tracking-results/$number',
          ),
        ),
        'AU' => (
          'Australia Post',
          Uri.https('auspost.com.au', '/mypost/track/details/$number'),
        ),
        // Every other postal service: a tracker that knows them all.
        _ => ('Post', Uri.parse('https://t.17track.net/en#nums=$number')),
      };
    } else {
      return null;
    }
    final (carrier, page) = parcel;
    return ClipLink._(ClipLinkKind.tracking, page, number, service: carrier);
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

  /// USPS (IMpb): from the right, leaving out the check digit, every other
  /// digit three times starting with the first; the check digit brings the
  /// sum to a ten.
  static bool _uspsCheckDigitOk(String number) {
    var sum = 0;
    for (var i = number.length - 2, weight = 3; i >= 0; i--) {
      sum += (number.codeUnitAt(i) - 48) * weight;
      weight = weight == 3 ? 1 : 3;
    }
    return (10 - sum % 10) % 10 == number.codeUnitAt(number.length - 1) - 48;
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
    // No number is written with a leading minus: that is a negative
    // quantity or a longitude (`-122.4194`).
    if (number.startsWith('-') ||
        _ipv4.hasMatch(number) ||
        _date.hasMatch(number) ||
        _ssn.hasMatch(number)) {
      return null;
    }
    final digits = number.replaceAll(_nonDigit, '');
    if (digits.length < 7 || digits.length > 15) return null;
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
      !(kind == ClipLinkKind.phone && platform == 'linux') &&
      // Apps that exist only on Apple devices: elsewhere nothing opens them.
      !(_appleOnlySchemes.contains(uri.scheme) &&
          platform != 'macos' &&
          platform != 'ios') &&
      // Editors that exist only on desktops: a phone has nothing for them.
      !(_editorSchemes.contains(uri.scheme) &&
          (platform == 'android' || platform == 'ios'));

  static const _appleOnlySchemes = {
    'things',
    'drafts',
    'bear',
    'facetime',
    'facetime-audio',
  };

  // Detection decoded this path already, so it decodes.
  String get _telPath => Uri.decodeComponent(uri.path);

  /// The second thing to do with it on [platform], or null where there is
  /// none:
  ///
  /// - A phone number can be texted as well as called (`sms:`; Messages on
  ///   a Mac, Phone Link on Windows) - wherever it can be called, so not on
  ///   Linux, which has nothing for `sms:` either.
  /// - A song or album can be found on the other services through song.link,
  ///   which is what makes an Apple Music link useful on a phone with only
  ///   Spotify, and the other way round. Not for podcasts, playlists or
  ///   artists, which song.link has nothing for.
  ClipLinkAlternate? alternateOn(String platform) {
    if (!canOpenOn(platform)) return null;
    switch (kind) {
      case ClipLinkKind.phone:
        // Decoded, as detection read it: `%3B` is a `;` there too.
        final path = _telPath;
        // A local number's `phone-context` says which country and area it
        // is in; `sms:` has no way to carry it, and the number alone could
        // reach someone else. Call keeps it; Text is left out.
        if (path.toLowerCase().contains(';phone-context=')) return null;
        // The number alone: a tel: link's other parameters (;ext=456) mean
        // nothing to a text.
        return ClipLinkAlternate(
          ClipLinkAlternateKind.text,
          'Text',
          Uri(scheme: 'sms', path: path.split(';').first),
        );
      case ClipLinkKind.music:
        final target = _songLinkTarget;
        if (target == null) return null;
        return ClipLinkAlternate(
          ClipLinkAlternateKind.findElsewhere,
          'Find on other services',
          Uri.parse('https://song.link/$target'),
        );
      default:
        return null;
    }
  }

  // The services whose paths name what they lead to - not Pandora, which
  // keeps tracks under /artist/, nor SoundCloud, whose paths are a user's own
  // names - and their short-link hosts, whose paths say nothing.
  static const _routedMusic = {
    'Spotify',
    'Apple Music',
    'TIDAL',
    'Deezer',
    'Amazon Music',
    'Bandcamp',
  };
  static const _shortMusicHosts = {'spotify.link', 'deezer.page.link'};

  /// The segments before a music service's route: a storefront country
  /// (`/us/`), Spotify's `/intl-de/`, TIDAL's `/browse/`.
  static final _routePrefix = RegExp(
    r'^([a-z]{2}(-[a-z]{2})?|intl-[a-z]{2}|browse)$',
  );
  static const _itemRoutes = {'track', 'tracks', 'album', 'albums', 'song'};

  /// Whether [path]'s route - its first segment past any [_routePrefix] - is
  /// a track or an album, not merely a segment named so further along
  /// (`/us/playlist/album/pl.abc`, a playlist titled "album")...
  /// ...and then names one: `/track/<id>`, not a bare `/track`.
  static bool _isTrackOrAlbum(String path) => switch (path
      .split(_routeSeparator)
      .where((s) => s.isNotEmpty)
      .skipWhile((s) => _routePrefix.hasMatch(s.toLowerCase()))
      .toList()) {
    [final route, _, ...] => _itemRoutes.contains(route.toLowerCase()),
    _ => false,
  };
  static final _routeSeparator = RegExp('[/:]');
  static final _pathStart = RegExp('[/?#]');

  /// SoundCloud's own pages, where a user's name would otherwise be.
  static const _soundCloudSite = {
    'search',
    'discover',
    'stream',
    'you',
    'charts',
    'upload',
    'settings',
    'messages',
    'notifications',
    'people',
    'tags',
    'pages',
    'stations',
  };
  static final _pandoraItem = RegExp(r'^(AL|TR)[A-Za-z0-9]+$');

  /// A SoundCloud user's own pages, beside their tracks at `/<user>/<track>`.
  static const _soundCloudPages = {
    'sets',
    'tracks',
    'albums',
    'popular-tracks',
    'likes',
    'reposts',
    'followers',
    'following',
    'comments',
  };

  /// The link song.link is given for a song or album, or null for what it
  /// cannot resolve.
  ///
  /// An Apple Music track is the album's link with the track in `?i=`
  /// (`/album/x/123?i=456`), a query that song.link, which takes the link as
  /// its own path, can read as its own and resolve the album: it is given as
  /// the track's own `/song/` link instead.
  String? get _songLinkTarget {
    // On those services, a link to anything but a track or album - Liked
    // Songs, a search, a radio station, a Mix, an artist's merch - is nothing
    // song.link resolves. Short links are given the benefit of the doubt.
    if (_routedMusic.contains(service) &&
        !_shortMusicHosts.contains(uri.host) &&
        !_isTrackOrAlbum(uri.path)) {
      return null;
    }
    if (service == 'Apple Podcasts') return null;
    // A SoundCloud track is /<user>/<track>: not a profile (/<user>), nor a
    // set, which is a playlist, nor the user's other pages. Its short links
    // say nothing in the path.
    if (service == 'SoundCloud' && uri.host != 'on.soundcloud.com') {
      final segments = _segments(uri);
      if (segments.length < 2 ||
          _soundCloudSite.contains(segments[0].toLowerCase()) ||
          _soundCloudPages.contains(segments[1].toLowerCase())) {
        return null;
      }
    }
    // A Pandora album or track sits under its artist and ends in its id:
    // /artist/<artist>/<album>/AL..., /artist/<artist>/<album>/<track>/TR....
    // Its share links say nothing in the path.
    if (service == 'Pandora' && uri.host != 'pandora.app.link') {
      final segments = _segments(uri);
      if (segments.firstOrNull?.toLowerCase() != 'artist' ||
          !_pandoraItem.hasMatch(segments.last)) {
        return null;
      }
    }
    // On YouTube Music, a song (/watch) or an album: its /browse/MPREb page,
    // or a playlist whose id starts OLAK5uy. Any other playlist is someone's
    // list, and a channel an artist, neither of which song.link resolves.
    if (service == 'YouTube Music' &&
        !switch ([for (final s in _segments(uri)) s.toLowerCase()]) {
          ['watch'] => (uri.queryParameters['v'] ?? '').isNotEmpty,
          ['browse', final id] => id.startsWith('mpreb'),
          ['playlist'] => (uri.queryParameters['list'] ?? '').startsWith(
            'OLAK5uy',
          ),
          _ => false,
        }) {
      return null;
    }
    final track = uri.queryParameters['i'];
    if (service == 'Apple Music' && track != null && track.isNotEmpty) {
      final country = uri.pathSegments.firstOrNull;
      return Uri.https(
        'music.apple.com',
        '/${country != null && country.length == 2 ? country : 'us'}/song/$track',
      ).toString();
    }
    return uri.toString();
  }

  /// Whether Open names the app that will open it, once that is known
  /// ("Open in Google Maps"). Calls, meetings and parcels keep their own
  /// verb: "Join meeting" and "Track package" say more than "Open in Zoom" or
  /// "Open in Safari" would.
  bool get namesHandler => switch (kind) {
    ClipLinkKind.phone ||
    ClipLinkKind.meeting ||
    ClipLinkKind.tracking => false,
    _ => true,
  };

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
  // google.com and Google's country domains (google.ca, google.co.uk,
  // google.com.au) - not any host that starts google., which
  // google.com.evil does.
  static final _googleHost = RegExp(
    r'^(www\.|maps\.)?google\.(com|[a-z]{2}|co\.[a-z]{2}|com\.[a-z]{2})$',
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
      if (host == 'goo.gl' && segments.firstOrNull != 'maps') {
        return null;
      }
      return const _MapPlace(_MapSource.google, isShortLink: true);
    }
    if (!_googleHost.hasMatch(host)) return null;
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
    var coords = uri.path.split(';').first;
    final parts = coords.split(',');
    if (parts.length == 3 && _number.hasMatch(parts[2].trim())) {
      coords = '${parts[0]},${parts[1]}';
    }
    final latLng = _latLngOrNull(coords);
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
        );
      }
    }
    final hasQuery = query != null && query.isNotEmpty;
    // geo:0,0 is the "no coordinate, search instead" form.
    final realLatLng = latLng == '0,0' ? null : latLng;
    if (realLatLng == null && !hasQuery) return null;
    return _MapPlace(
      _MapSource.geo,
      query: hasQuery ? query : null,
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
