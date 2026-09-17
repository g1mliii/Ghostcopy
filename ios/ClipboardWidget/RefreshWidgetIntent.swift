/// App Intents backing the widget's two interactions: the refresh button and
/// tapping a text row to copy it.
///
/// Both run inside the widget process and touch nothing but the App Group and
/// the pasteboard - no network, no Supabase client, no decryption. See
/// RefreshWidgetIntent's note for why fetching here cannot work.
import AppIntents
import UIKit
import WidgetKit

@available(iOS 17.0, *)
struct RefreshWidgetIntent: AppIntent {
    static var title: LocalizedStringResource = "Refresh Clipboard Widget"
    static var description = IntentDescription("Show the latest clipboard items")

    /// Re-render from the App Group. Deliberately no network call.
    ///
    /// This used to fetch from PostgREST itself, with the publishable key and
    /// a `user_id=eq.` filter. That could never have returned anything:
    ///
    /// - The SELECT policy on `clipboard` is granted `TO authenticated`, and a
    ///   publishable key authenticates as `anon`. RLS denies every row, whatever
    ///   the filter says. It would need a real user JWT, which would mean
    ///   keeping a refreshable session in the shared container.
    /// - It read `content_preview` and `thumbnail_path`, neither of which are
    ///   columns on that table.
    /// - `content` is ciphertext whenever `is_encrypted` is set, and the
    ///   widget has no access to the key. Even given rows, it would have
    ///   replaced readable previews with encrypted blobs.
    ///
    /// The widget is a view over what the app last wrote, and the app is the
    /// only thing that can decrypt. Writers are the app on history load and
    /// AppDelegate when an FCM notification arrives; this just re-reads their
    /// work, which also refreshes the relative timestamps that would otherwise
    /// sit still under the `.never` timeline policy.
    @MainActor
    func perform() async throws -> some IntentResult {
        WidgetCenter.shared.reloadAllTimelines()
        return .result()
    }
}

@available(iOS 17.0, *)
struct CopyToClipboardIntent: AppIntent {
    static var title: LocalizedStringResource = "Copy to Clipboard"

    @Parameter(title: "Clipboard ID") var clipboardId: String
    @Parameter(title: "Content") var content: String

    init() {}

    init(clipboardId: String, content: String) {
        self.clipboardId = clipboardId
        self.content = content
    }

    /// Writes the pasteboard from inside the widget process, so a text clip is
    /// copied without GhostCopy ever appearing. UIPasteboard is available to an
    /// extension - it is presenting UI that a widget cannot do, not copying.
    ///
    /// `content` is the full clip. It used to be `contentPreview`, which is cut
    /// to 50 characters with an ellipsis, so every longer clip copied a mangled
    /// string and looked like it had worked.
    ///
    /// Only rows the app sent a copyText for reach this; files and images have
    /// no payload on the device to copy and open the app instead.
    @MainActor
    func perform() async throws -> some IntentResult {
        UIPasteboard.general.string = content
        return .result()
    }
}
