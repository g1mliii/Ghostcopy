/// Whether the IPv4 address [b] (four bytes) is anything but a public
/// internet address: a machine on the user's own network
/// ([isLocalUnicastIPv4]) or one of the blocks no server is reached at
/// ([isReservedIPv4]).
///
/// Shared by the webhook guard, which refuses to post to such an address, and
/// link detection, which treats a bare one as a machine on the user's own
/// network worth an Open button.
bool isNonPublicIPv4(List<int> b) => isLocalUnicastIPv4(b) || isReservedIPv4(b);

/// Whether the IPv4 address [b] (four bytes) is a machine on the user's own
/// network or this one: private networks, loopback, link-local and
/// carrier-grade NAT (Tailscale's range; 169.254/16 covers the cloud
/// metadata endpoint).
bool isLocalUnicastIPv4(List<int> b) =>
    b[0] == 10 ||
    b[0] == 127 ||
    (b[0] == 169 && b[1] == 254) ||
    (b[0] == 172 && b[1] >= 16 && b[1] <= 31) ||
    (b[0] == 192 && b[1] == 168) ||
    (b[0] == 100 && b[1] >= 64 && b[1] <= 127);

/// Whether the IPv4 address [b] (four bytes) is in a block no server is
/// reached at: "this network", protocol assignments, documentation,
/// benchmarking, multicast and the reserved range - addresses no browser
/// opens a page on, which link detection must not offer one for.
bool isReservedIPv4(List<int> b) =>
    // 0.0.0.0/8 - "this network"
    b[0] == 0 ||
    // 192.0.0.0/24 - IETF protocol assignments
    (b[0] == 192 && b[1] == 0 && b[2] == 0) ||
    // 192.0.2.0/24, 198.51.100.0/24, 203.0.113.0/24 - documentation
    (b[0] == 192 && b[1] == 0 && b[2] == 2) ||
    (b[0] == 198 && b[1] == 51 && b[2] == 100) ||
    (b[0] == 203 && b[1] == 0 && b[2] == 113) ||
    // 198.18.0.0/15 - benchmarking
    (b[0] == 198 && (b[1] == 18 || b[1] == 19)) ||
    // 224.0.0.0/4 multicast and 240.0.0.0/4 reserved
    b[0] >= 224;

/// The IPv4 address an IPv4-mapped IPv6 address [b] (sixteen bytes,
/// `::ffff:a.b.c.d`) stands for, or null if it is not one. Such an address
/// is judged as the IPv4 address it wraps, or a rule on IPv4 addresses could
/// be stepped round just by writing one in IPv6 form.
List<int>? ipv4Mapped(List<int> b) =>
    b.take(10).every((x) => x == 0) && b[10] == 0xff && b[11] == 0xff
    ? b.sublist(12)
    : null;

/// Whether the IPv6 address [b] (sixteen bytes) is one no browser opens a
/// page on: unspecified (`::`), multicast (ff00::/8), documentation
/// (2001:db8::/32, 3fff::/20), or an IPv4-mapped address in an
/// [isReservedIPv4] block.
bool isUnservableIPv6(List<int> b) {
  if (b[0] == 0xff || b.every((x) => x == 0)) return true;
  if ((b[0] == 0x20 && b[1] == 0x01 && b[2] == 0x0d && b[3] == 0xb8) ||
      (b[0] == 0x3f && b[1] == 0xff && b[2] < 0x10)) {
    return true;
  }
  final v4 = ipv4Mapped(b);
  return v4 != null && isReservedIPv4(v4);
}
