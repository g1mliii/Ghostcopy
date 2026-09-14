/// Size limits for clipboard payloads.
///
/// One definition for the whole Dart side. These used to be independent
/// literals at ten call sites, spelled three different ways (`10485760`,
/// `10 * 1024 * 1024`, a private `_maxFileBytes`), which meant changing the
/// limit required finding all of them - and missing one turned a friendly
/// client-side rejection into a server 400 or a constraint violation after the
/// user had already waited through a full upload.
///
/// The authority is the `CHECK` constraint in `supabase/schema.sql`; the edge
/// functions and the native share handlers enforce the same numbers on their
/// own side of the wire. Change all three together.
class ClipboardLimits {
  const ClipboardLimits._();

  /// Largest attachment accepted, in bytes (10 MB).
  static const int maxFileBytes = 10 * 1024 * 1024;

  /// Above this, sending is confirmed with the user first (5 MB).
  static const int largeFileWarningBytes = 5 * 1024 * 1024;

  /// Human-readable form of [maxFileBytes], for error messages.
  static String get maxFileLabel => '${maxFileBytes ~/ (1024 * 1024)}MB';
}
