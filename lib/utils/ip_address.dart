/// Whether the IPv4 address [b] (four bytes) is anything but a public
/// internet address: private networks, loopback, link-local, carrier-grade NAT
/// (Tailscale's range), and the reserved, benchmarking and multicast blocks.
///
/// Shared by the webhook guard, which refuses to post to such an address, and
/// link detection, which treats a bare one as a machine on the user's own
/// network worth an Open button.
bool isNonPublicIPv4(List<int> b) {
  // 0.0.0.0/8 - "this network"
  if (b[0] == 0) return true;
  // 10.0.0.0/8
  if (b[0] == 10) return true;
  // 127.0.0.0/8 - loopback
  if (b[0] == 127) return true;
  // 169.254.0.0/16 - link-local, covers the cloud metadata endpoint
  if (b[0] == 169 && b[1] == 254) return true;
  // 172.16.0.0/12
  if (b[0] == 172 && b[1] >= 16 && b[1] <= 31) return true;
  // 192.168.0.0/16
  if (b[0] == 192 && b[1] == 168) return true;
  // 100.64.0.0/10 - carrier-grade NAT
  if (b[0] == 100 && b[1] >= 64 && b[1] <= 127) return true;
  // 192.0.0.0/24 - IETF protocol assignments
  if (b[0] == 192 && b[1] == 0 && b[2] == 0) return true;
  // 198.18.0.0/15 - benchmarking
  if (b[0] == 198 && (b[1] == 18 || b[1] == 19)) return true;
  // 224.0.0.0/4 multicast and 240.0.0.0/4 reserved
  if (b[0] >= 224) return true;

  return false;
}
