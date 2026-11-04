/// Whether the IPv4 address [b] (four bytes) is anything but a public
/// internet address: private networks, loopback, link-local, carrier-grade NAT
/// (Tailscale's range), and the reserved, benchmarking and multicast blocks.
///
/// Shared by the webhook guard, which refuses to post to such an address, and
/// link detection, which treats a bare one as a machine on the user's own
/// network worth an Open button.
bool isNonPublicIPv4(List<int> b) =>
    // Private, loopback, link-local and carrier-grade NAT.
    isLocalUnicastIPv4(b) ||
    // 0.0.0.0/8 - "this network"
    b[0] == 0 ||
    // 192.0.0.0/24 - IETF protocol assignments
    (b[0] == 192 && b[1] == 0 && b[2] == 0) ||
    // 198.18.0.0/15 - benchmarking
    (b[0] == 198 && (b[1] == 18 || b[1] == 19)) ||
    // 224.0.0.0/4 multicast and 240.0.0.0/4 reserved
    b[0] >= 224;

/// Whether the IPv4 address [b] (four bytes) is a machine on the user's own
/// network or this one: private networks, loopback, link-local and
/// carrier-grade NAT (Tailscale's range; 169.254/16 covers the cloud
/// metadata endpoint). Unlike [isNonPublicIPv4], not the
/// reserved, benchmarking and multicast blocks - addresses no browser opens
/// a page on, which link detection must not offer one for.
bool isLocalUnicastIPv4(List<int> b) =>
    b[0] == 10 ||
    b[0] == 127 ||
    (b[0] == 169 && b[1] == 254) ||
    (b[0] == 172 && b[1] >= 16 && b[1] <= 31) ||
    (b[0] == 192 && b[1] == 168) ||
    (b[0] == 100 && b[1] >= 64 && b[1] <= 127);
