/// The widget's one interaction: tapping a row to copy it.
///
/// This runs inside the widget process and touches nothing but the App Group
/// and the pasteboard - no network, no Supabase client, no decryption. The app
/// stages the payload already decrypted, because the widget cannot reach the
/// key and a widget that shows ciphertext is no use to anyone.
///
/// There is no refresh intent any more. It fetched from PostgREST with the
/// publishable key, which authenticates as `anon` against a SELECT policy
/// granted TO authenticated - so it could never return a row, quite apart from
/// reading two columns that do not exist and having no way to decrypt what it
/// would have got. Reduced to a timeline reload it was a button that re-drew
/// the same pixels, so it is gone; the app and incoming notifications keep the
/// widget current.
import AppIntents
import UIKit
import WidgetKit

@available(iOS 17.0, *)
struct CopyToClipboardIntent: AppIntent {
    static var title: LocalizedStringResource = "Copy to Clipboard"

    @Parameter(title: "Clipboard ID") var clipboardId: String
    @Parameter(title: "Payload Path") var copyPath: String
    @Parameter(title: "Payload Kind") var copyKind: String

    init() {}

    init(clipboardId: String, copyPath: String, copyKind: String) {
        self.clipboardId = clipboardId
        self.copyPath = copyPath
        self.copyKind = copyKind
    }

    /// UIPasteboard is available to an extension - presenting UI is what a
    /// widget cannot do, not copying.
    ///
    /// The payload is read from a file. It used to be `contentPreview`, which
    /// is cut to a preview length for the row, so every longer clip copied a
    /// mangled string and looked like it had worked. Images had the same
    /// problem in a different shape: the only image on the device was the 40px
    /// thumbnail, so "copy" produced a 40px picture.
    @MainActor
    func perform() async throws -> some IntentResult {
        var copied = false

        if copyKind == "image", let image = UIImage(contentsOfFile: copyPath) {
            UIPasteboard.general.image = image
            // Read back rather than assume. Writing UIPasteboard is IPC to
            // `pasted`, and a widget's extension process is torn down promptly
            // after perform() returns - so a write that is only queued can be
            // lost. Reading forces the round trip to finish while this process
            // is still alive, and tells us it actually landed.
            //
            // No "Allow Paste?" prompt: that appears when reading content
            // another app wrote. This process owns what it just put there.
            copied = UIPasteboard.general.hasImages
        } else if let text = try? String(contentsOfFile: copyPath, encoding: .utf8),
            !text.isEmpty
        {
            UIPasteboard.general.string = text
            copied = UIPasteboard.general.string == text
        }

        // Only claim success when the pasteboard really holds the clip. The
        // marker below drives the "Copied" banner, and a banner over a
        // clipboard that never changed is worse than no banner at all.
        guard copied else { return .result() }

        // Leave a marker the timeline turns into a "Copied" confirmation. The
        // widget renders snapshots, not live views, so the acknowledgement has
        // to come back round through a reload.
        if let defaults = UserDefaults(suiteName: WidgetDataManager.appGroupSuite) {
            defaults.set(clipboardId, forKey: WidgetDataManager.lastCopiedIdKey)
            defaults.set(Date().timeIntervalSince1970, forKey: WidgetDataManager.lastCopiedAtKey)
        }

        WidgetCenter.shared.reloadAllTimelines()
        return .result()
    }
}
