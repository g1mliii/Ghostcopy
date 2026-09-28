import UIKit
import UniformTypeIdentifiers
import receive_sharing_intent

/// Entry point for the iOS share sheet.
///
/// Attachments are loaded here, not by the package. RSIShareViewController is
/// kept for its setup (the app group id, the clear background) and for the
/// payload the plugin reads back on the other side - `ShareKey` in the App
/// Group's defaults, then `ShareMedia-<bundle id>` to open the app - but its
/// loader is not used.
///
/// That loader tries types in a fixed order - image, video, text, file, url -
/// asks for the first one an attachment conforms to, and then expects one
/// particular class back. When iOS hands back anything else it does nothing:
/// no save, no redirect, no error, and the request is never completed, so the
/// share sheet just sits there. Two ways into that, both seen on device:
///
///  - Messages offers a message as `com.apple.uikit.attributedstring`,
///    `com.apple.flat-rtfd`, `public.utf8-plain-text`, and hands back an
///    NSAttributedString where the loader wanted a String.
///  - A document - a .txt, a Jetsam `.ips` log - conforms to `public.text`,
///    so it was asked for as text and came back as a file URL. Sharing a
///    409 KB log hung the sheet this way.
///
/// Here what comes back decides what is sent. A file on disk is sent as that
/// file whatever type it was asked for as, so sharing a document sends the
/// document rather than its contents; only real text is sent as text. And
/// every attachment finishes, loaded or not, so the request always completes.
///
/// Auto-redirect is left on. The package can show a compose sheet of its own
/// instead, but sending goes to the devices in "Send to devices" without
/// asking, so there is nothing to compose.
class ShareViewController: RSIShareViewController {

    /// Longest a share may take to load before it is sent with what arrived.
    /// Generous, because a video still in iCloud downloads first.
    private static let loadTimeout: TimeInterval = 60

    /// How long an earlier share's copied files are kept. The app reads them
    /// as soon as it opens; this only bounds what an abandoned share leaves.
    private static let staleShareAge: TimeInterval = 24 * 60 * 60

    /// Set once the share has been handed over or given up, so the timeout and
    /// the last attachment cannot both finish it.
    private var finished = false

    override func viewDidAppear(_ animated: Bool) {
        // Not super: RSIShareViewController.viewDidAppear starts the package's
        // loader, which is what this replaces.
        loadAttachments()
    }

    private func loadAttachments() {
        let items = extensionContext?.inputItems.compactMap { $0 as? NSExtensionItem } ?? []
        let providers = items.flatMap { $0.attachments ?? [] }
        let fallbackText = items.first?.attributedContentText?.string
        let directory = Self.makeShareDirectory()

        let lock = NSLock()
        var loaded: [Int: SharedMediaFile] = [:]
        func inOrder() -> [SharedMediaFile] {
            lock.lock()
            defer { lock.unlock() }
            return loaded.keys.sorted().compactMap { loaded[$0] }
        }

        let group = DispatchGroup()
        for (index, provider) in providers.enumerated() {
            group.enter()
            Self.load(provider, into: directory) { media in
                if let media = media {
                    lock.lock()
                    loaded[index] = media
                    lock.unlock()
                }
                group.leave()
            }
        }

        group.notify(queue: .main) { [weak self] in
            var media = inOrder()
            if media.isEmpty, let text = fallbackText, !text.isEmpty {
                media = [SharedMediaFile(path: text, mimeType: "text/plain", type: .text)]
            }
            self?.finish(with: media)
        }

        // A load that never calls back must not leave the sheet up for good.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.loadTimeout) { [weak self] in
            self?.finish(with: inOrder())
        }
    }

    // MARK: - Loading

    /// Load one attachment, calling [completion] exactly once.
    private static func load(
        _ provider: NSItemProvider,
        into directory: URL?,
        completion: @escaping (SharedMediaFile?) -> Void
    ) {
        guard let match = Self.kind(of: provider) else {
            // Nothing below applies - a PDF or a contact card from some apps.
            // Taken as a file of whatever type it declares.
            guard let type = provider.registeredTypeIdentifiers.first else {
                return completion(nil)
            }
            _ = provider.loadFileRepresentation(forTypeIdentifier: type) { url, error in
                if let error = error { NSLog("[ShareExtension] File load failed: \(error)") }
                // The file is deleted when this handler returns, so it is
                // copied here rather than later.
                completion(url.flatMap { Self.copy($0, as: .file, into: directory) })
            }
            return
        }

        let (kind, typeIdentifier) = match
        if kind == .image {
            // The image's file, copied as bytes. Asking for the item instead
            // can hand back a decoded UIImage, and re-encoding a camera photo
            // at full size - several at once - is enough to get the extension
            // killed for memory before it writes anything.
            _ = provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { url, error in
                if let url = url, let file = Self.copy(url, as: .image, into: directory) {
                    return completion(file)
                }
                if let error = error { NSLog("[ShareExtension] Image file load failed: \(error)") }
                Self.loadItem(provider, kind: kind, typeIdentifier: typeIdentifier,
                              directory: directory, completion: completion)
            }
            return
        }
        loadItem(provider, kind: kind, typeIdentifier: typeIdentifier,
                 directory: directory, completion: completion)
    }

    private static func loadItem(
        _ provider: NSItemProvider,
        kind: SharedMediaType,
        typeIdentifier: String,
        directory: URL?,
        completion: @escaping (SharedMediaFile?) -> Void
    ) {
        provider.loadItem(forTypeIdentifier: typeIdentifier, options: nil) { data, error in
            if let error = error { NSLog("[ShareExtension] Load failed: \(error)") }
            // Also inside the handler: a file URL handed to it may be valid
            // only until it returns.
            completion(
                Self.media(from: data, kind: kind, provider: provider, directory: directory))
        }
    }

    /// What to ask an attachment for. Only a first guess: [media] decides
    /// from what actually comes back.
    ///
    /// `public.file-url` comes before `public.url`, which it conforms to, and
    /// both come before text, so a link is sent as a link.
    private static func kind(of provider: NSItemProvider) -> (SharedMediaType, String)? {
        let candidates: [(SharedMediaType, UTType)] = [
            (.video, .movie),
            (.image, .image),
            (.file, .fileURL),
            (.url, .url),
            (.text, .text),
        ]
        return candidates
            .first { provider.hasItemConformingToTypeIdentifier($0.1.identifier) }
            .map { ($0.0, $0.1.identifier) }
    }

    /// Turn whatever `loadItem` handed back into something to send.
    ///
    /// The type identifier asked for does not decide the class of the value:
    /// the same `public.text` yields a String from Safari, an
    /// NSAttributedString from Messages, and a file URL from Files.
    private static func media(
        from data: NSSecureCoding?,
        kind: SharedMediaType,
        provider: NSItemProvider,
        directory: URL?
    ) -> SharedMediaFile? {
        guard let data = data else { return nil }
        let value: Any = data
        switch value {
        case let url as URL where url.isFileURL:
            // A document is not its text: whatever it was asked for as, a
            // file on disk is sent as that file.
            let type: SharedMediaType = (kind == .image || kind == .video) ? kind : .file
            return copy(url, as: type, into: directory)
        case let url as URL:
            return SharedMediaFile(path: url.absoluteString, type: .url)
        case let string as String:
            return text(string)
        case let attributed as NSAttributedString:
            return text(attributed.string)
        case let image as UIImage:
            // Only when no file was offered. JPEG, not PNG: a fraction of the
            // size and of the encoding memory for a photo.
            guard let jpeg = image.jpegData(compressionQuality: 0.9) else { return nil }
            return write(jpeg, named: "\(UUID().uuidString).jpg", as: .image, into: directory)
        case let raw as Data:
            // Unnamed bytes offered as text are text. Anything with a file
            // name, or that is not text at all, is a file.
            if kind == .text, provider.suggestedName == nil,
                let string = String(data: raw, encoding: .utf8)
            {
                return text(string)
            }
            return write(
                raw,
                named: fileName(for: provider),
                as: kind == .image ? .image : .file,
                into: directory)
        default:
            return nil
        }
    }

    private static func text(_ string: String) -> SharedMediaFile? {
        string.isEmpty ? nil : SharedMediaFile(path: string, mimeType: "text/plain", type: .text)
    }

    /// The provider's own name for the item, with the extension its type
    /// implies when the name lacks one.
    private static func fileName(for provider: NSItemProvider) -> String {
        let fileExtension = provider.registeredTypeIdentifiers.lazy
            .compactMap { UTType($0)?.preferredFilenameExtension }
            .first
        let base = provider.suggestedName ?? UUID().uuidString
        guard let fileExtension = fileExtension,
            (base as NSString).pathExtension.isEmpty
        else {
            return base
        }
        return "\(base).\(fileExtension)"
    }

    // MARK: - Files

    /// A new folder for this share's files in the App Group container, where
    /// the app reads them. Its own folder so two files with the same name in
    /// one share do not overwrite each other, and the file keeps its name -
    /// the app labels the clip with it.
    private static func makeShareDirectory() -> URL? {
        guard let groupId = Bundle.main.object(forInfoDictionaryKey: kAppGroupIdKey) as? String,
            let container = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: groupId)
        else {
            return nil
        }
        let shares = container.appendingPathComponent("Shares", isDirectory: true)
        removeStaleShares(in: shares)
        let directory = shares.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            return directory
        } catch {
            NSLog("[ShareExtension] Cannot create share folder: \(error)")
            return nil
        }
    }

    private static func removeStaleShares(in shares: URL) {
        let fileManager = FileManager.default
        guard
            let folders = try? fileManager.contentsOfDirectory(
                at: shares, includingPropertiesForKeys: [.creationDateKey])
        else {
            return
        }
        let cutoff = Date().addingTimeInterval(-staleShareAge)
        for folder in folders {
            let created = (try? folder.resourceValues(forKeys: [.creationDateKey]))?.creationDate
            if let created = created, created < cutoff {
                try? fileManager.removeItem(at: folder)
            }
        }
    }

    private static func destination(named name: String, in directory: URL?) -> URL? {
        guard let directory = directory else { return nil }
        // suggestedName belongs to the source app. Never let it select a
        // parent directory, and retain only a usable basename.
        let basename = (name as NSString).lastPathComponent
        let safeName = basename.isEmpty || basename == "." || basename == ".."
            ? UUID().uuidString : basename
        // Each callback owns its directory, even when providers finish at
        // the same time with identical names. No check-then-write race.
        let itemDirectory = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: itemDirectory, withIntermediateDirectories: false)
            return itemDirectory.appendingPathComponent(safeName)
        } catch {
            NSLog("[ShareExtension] Cannot create attachment folder: \(error)")
            return nil
        }
    }

    private static func copy(
        _ source: URL, as type: SharedMediaType, into directory: URL?
    ) -> SharedMediaFile? {
        guard let target = destination(named: source.lastPathComponent, in: directory) else {
            return nil
        }
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        do {
            try FileManager.default.copyItem(at: source, to: target)
        } catch {
            NSLog("[ShareExtension] Cannot copy shared file: \(error)")
            return nil
        }
        return sharedFile(at: target, type: type)
    }

    private static func write(
        _ data: Data, named name: String, as type: SharedMediaType, into directory: URL?
    ) -> SharedMediaFile? {
        guard let target = destination(named: name, in: directory) else { return nil }
        do {
            try data.write(to: target)
        } catch {
            NSLog("[ShareExtension] Cannot write shared data: \(error)")
            return nil
        }
        return sharedFile(at: target, type: type)
    }

    /// In the form the package itself records a file: its `file://` URL with
    /// percent-encoding removed, which the plugin turns back into a path.
    private static func sharedFile(at url: URL, type: SharedMediaType) -> SharedMediaFile? {
        guard let path = url.absoluteString.removingPercentEncoding else { return nil }
        return SharedMediaFile(path: path, mimeType: url.mimeType(), type: type)
    }

    // MARK: - Handing over

    /// Write the share where the plugin reads it, then open the app. With
    /// nothing usable, just close the sheet rather than leave it up.
    private func finish(with media: [SharedMediaFile]) {
        guard !finished else { return }
        finished = true

        guard !media.isEmpty else {
            extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
            return
        }

        // Same container, key and JSON shape as the package's saveAndRedirect;
        // its `sharedMedia` is internal to that module, so the payload is
        // assembled here.
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
