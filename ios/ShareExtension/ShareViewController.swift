import UIKit
import UniformTypeIdentifiers
import receive_sharing_intent

/// Entry point for the iOS share sheet.
///
/// RSIShareViewController does the work for images, files and URLs: it copies
/// the attachments into the App Group container and opens the host app on
/// `ShareMedia-<bundle id>`, which ReceiveSharingIntentPlugin turns back into
/// the SharedMediaFile list the app listens for.
///
/// Auto-redirect is left on. The package can show a compose sheet of its own
/// instead, but sending goes to the devices in "Send to devices" without
/// asking, so there is nothing to compose.
class ShareViewController: RSIShareViewController {

    /// Text shares are handled here rather than by the package.
    ///
    /// The package matches any attachment conforming to `public.text`, calls
    /// `loadItem(forTypeIdentifier: "public.text")`, and then does
    /// `if let text = data as? String`. When the attachment's real
    /// representation is rich text that cast fails, and because it only fires
    /// its redirect from the callback of the last attachment it recognised,
    /// nothing happens at all: no save, no redirect, no error - the sheet just
    /// sits there.
    ///
    /// Messages does exactly this. Measured on device, sharing a message
    /// offers:
    ///
    ///     com.apple.uikit.attributedstring, com.apple.flat-rtfd,
    ///     public.utf8-plain-text
    ///
    /// which advertises plain text but hands back an NSAttributedString. A
    /// watchdog confirmed the extension was still presented six seconds later
    /// with no redirect. Safari, Photos and PDF shares were unaffected.
    override func viewDidAppear(_ animated: Bool) {
        if takeOverTextShare() { return }
        super.viewDidAppear(animated)
    }

    /// Returns true when this class has taken responsibility for the share.
    private func takeOverTextShare() -> Bool {
        guard let item = extensionContext?.inputItems.first as? NSExtensionItem,
            let attachment = item.attachments?.first,
            item.attachments?.count == 1,
            attachment.hasItemConformingToTypeIdentifier(UTType.text.identifier),
            // A .txt on disk is a file share; the package handles those, and
            // its path is what the app wants rather than the contents.
            !attachment.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        else {
            return false
        }

        attachment.loadItem(forTypeIdentifier: UTType.text.identifier) { [weak self] data, _ in
            let text = Self.plainText(from: data) ?? item.attributedContentText?.string
            DispatchQueue.main.async {
                guard let self = self else { return }
                guard let text = text, !text.isEmpty else {
                    // Nothing usable - dismiss rather than leave the sheet up.
                    self.extensionContext?.completeRequest(
                        returningItems: [], completionHandler: nil)
                    return
                }
                self.deliver(text: text)
            }
        }
        return true
    }

    /// Coerce whatever `loadItem` hands back into plain text.
    ///
    /// The declared type identifier does not decide the class of the value:
    /// the same `public.text` conformance yields a String from Safari and an
    /// NSAttributedString from Messages, and Data or a URL from others.
    private static func plainText(from data: Any?) -> String? {
        switch data {
        case let string as String:
            return string
        case let attributed as NSAttributedString:
            return attributed.string
        case let raw as Data:
            return String(data: raw, encoding: .utf8)
        case let url as URL:
            return url.absoluteString
        default:
            return nil
        }
    }

    /// Write the clip where the plugin reads it, then open the app.
    ///
    /// Same container, key and JSON shape the package's own saveAndRedirect
    /// uses - its `sharedMedia` is internal to that module, so the payload has
    /// to be assembled here rather than handed to it.
    private func deliver(text: String) {
        let media = [SharedMediaFile(path: text, mimeType: "text/plain", type: .text)]

        if let groupId = Bundle.main.object(forInfoDictionaryKey: kAppGroupIdKey) as? String,
            let defaults = UserDefaults(suiteName: groupId),
            let encoded = try? JSONEncoder().encode(media)
        {
            defaults.set(encoded, forKey: kUserDefaultsKey)
            defaults.synchronize()
        }

        openHostApp()
        extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
    }

    /// Open the host app on the scheme the plugin listens for.
    ///
    /// An extension has no UIApplication of its own, so the containing app's
    /// is reached through the responder chain - the same route the package
    /// takes.
    private func openHostApp() {
        guard let extensionId = Bundle.main.bundleIdentifier,
            let dot = extensionId.lastIndex(of: "."),
            let url = URL(string: "\(kSchemePrefix)-\(extensionId[..<dot]):share")
        else {
            return
        }

        var responder: UIResponder? = self
        while let current = responder {
            if let application = current as? UIApplication {
                application.open(url, options: [:], completionHandler: nil)
                return
            }
            responder = current.next
        }
    }
}
