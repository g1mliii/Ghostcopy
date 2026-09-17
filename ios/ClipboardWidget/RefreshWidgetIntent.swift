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
            copied = true
        } else if let text = try? String(contentsOfFile: copyPath, encoding: .utf8) {
            UIPasteboard.general.string = text
            copied = true
        }

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
