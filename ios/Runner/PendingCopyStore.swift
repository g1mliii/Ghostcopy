import Foundation

/// Reads the clip the Dart background isolate staged for instant copying.
///
/// The push deliberately carries no clipboard value - clips are encrypted, and
/// putting plaintext through APNs would defeat that. Instead the push names a
/// clip id, `_firebaseBackgroundHandler` in lib/main.dart fetches and decrypts
/// it over an RLS-scoped connection, and writes the plaintext to
/// `pending_copy.json`. This is the read side, and the direct counterpart of
/// Android's CopyActivity.
///
/// The file is deleted as soon as it is read, so plaintext is at rest only
/// between the push arriving and the user acting on it.
enum PendingCopyStore {
  private static let fileName = "pending_copy.json"

  struct PendingCopy {
    let id: String
    let content: String
    let contentType: String
  }

  /// Dart's getApplicationSupportDirectory() maps to Application Support inside
  /// the app container on iOS.
  private static var fileURL: URL? {
    FileManager.default
      .urls(for: .applicationSupportDirectory, in: .userDomainMask)
      .first?
      .appendingPathComponent(fileName)
  }

  /// Takes the staged clip, removing it in the process.
  ///
  /// Returns nil whenever the clip is not there to take - the isolate was never
  /// woken, the fetch failed, the file was already consumed. Every caller
  /// treats that as "fall back to opening the app", the same way Android does,
  /// because an iOS background wake-up is not guaranteed: the system throttles
  /// them on battery and usage grounds, so the prefetch can simply lose the
  /// race with the user.
  static func take() -> PendingCopy? {
    guard let url = fileURL,
      let data = try? Data(contentsOf: url),
      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let id = json["id"].map({ String(describing: $0) }),
      let content = json["content"] as? String,
      !content.isEmpty
    else {
      return nil
    }

    // Consume it whether or not the caller ends up using it: a stale clip is
    // worse than none, because it would put the wrong thing on the pasteboard
    // the next time a prefetch fails.
    try? FileManager.default.removeItem(at: url)

    let contentType = (json["contentType"] as? String) ?? "text"
    return PendingCopy(id: id, content: content, contentType: contentType)
  }

  /// Whether the staged clip is one the pasteboard can take directly.
  ///
  /// Only text. A file or image is stored as a reference, not as bytes that
  /// mean anything to UIPasteboard, so those still route into the app.
  static func isCopyableText(_ contentType: String) -> Bool {
    !contentType.hasPrefix("file_") && !contentType.hasPrefix("image_")
  }
}
