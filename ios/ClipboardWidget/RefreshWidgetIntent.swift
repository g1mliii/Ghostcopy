/// App Intent for manual widget refresh
/// Triggered when user taps the refresh button on the widget
///
/// Memory Management:
/// - Lightweight async operation
/// - Properly cancels URLSession tasks
/// - No retain cycles (escaping closures handled with weak self pattern)
import AppIntents

import UIKit

/// Copy to clipboard intent for widget tap
/// Triggered when user taps a clipboard item in the widget

// MARK: - Error Types

import WidgetKit

@available(iOS 17.0, *)
struct RefreshWidgetIntent: AppIntent {
    /// Must match the App Group in both targets' entitlements, and the one
    /// WidgetDataManager writes the clipboard rows to.
    static let appGroupIdentifier = "group.com.ghostcopy.app"

    static var title: LocalizedStringResource = "Refresh Clipboard Widget"
    static var description = IntentDescription("Refresh the clipboard widget with the latest items")

    // MARK: - Perform

    @MainActor
    func perform() async throws -> some IntentResult {
        print("[RefreshWidgetIntent] 🔄 Widget refresh triggered")

        do {
            // Credentials come from the App Group suite, not UserDefaults.standard.
            //
            // A widget extension is a separate process with its own container,
            // so `.standard` here is not the `.standard` the app writes to -
            // the two never meet. WidgetDataManager already uses the shared
            // suite for the clipboard rows; these were reading the one place
            // the app could never have put them, so this refresh path could
            // not have worked at all.
            guard let defaults = UserDefaults(suiteName: Self.appGroupIdentifier),
                let supabaseUrl = defaults.string(forKey: "supabase_url"),
                let anonKey = defaults.string(forKey: "supabase_anon_key")
            else {
                print("[RefreshWidgetIntent] ❌ Missing Supabase credentials")
                return .result()
            }

            // Fetch latest 5 items from Supabase
            let items = try await fetchLatestItems(
                from: supabaseUrl,
                anonKey: anonKey
            )

            // Update shared storage
            let dataManager = WidgetDataManager.shared
            dataManager.saveClipboardItems(items)

            print("[RefreshWidgetIntent] ✅ Refreshed widget with \(items.count) items")

            // Reload all timelines on success
            WidgetCenter.shared.reloadAllTimelines()
        } catch {
            print("[RefreshWidgetIntent] ❌ Refresh failed: \(error)")
        }

        return .result()
    }

    // MARK: - Private Methods

    /// Fetch latest clipboard items from Supabase REST API
    /// - Parameters:
    ///   - url: Supabase project URL
    ///   - anonKey: Supabase anonymous key
    /// - Returns: Array of clipboard item dictionaries
    /// - Throws: Network or parsing errors
    private func fetchLatestItems(
        from url: String,
        anonKey: String
    ) async throws -> [[String: Any]] {
        // Same suite as the credentials above, for the same reason.
        guard let defaults = UserDefaults(suiteName: Self.appGroupIdentifier),
            let userId = defaults.string(forKey: "user_id")
        else {
            print("[RefreshWidgetIntent] ⚠️ No user_id found, using empty list")
            return []
        }

        let apiUrl = URL(
            string: "\(url)/rest/v1/clipboard?user_id=eq.\(userId)&order=created_at.desc&limit=5")!

        var request = URLRequest(url: apiUrl)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(anonKey)", forHTTPHeaderField: "Authorization")

        // Create lightweight URLSession (no background tasks)
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 30
        let session = URLSession(configuration: config)

        let (data, response) = try await session.data(for: request)

        // Verify response
        guard let httpResponse = response as? HTTPURLResponse,
            httpResponse.statusCode == 200
        else {
            throw RefreshError.invalidResponse
        }

        // Parse JSON
        guard let jsonArray = try JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else {
            throw RefreshError.invalidJSON
        }

        // Format items for widget
        return jsonArray.map { item in
            let contentType = item["content_type"] as? String ?? "text"
            let isFile = contentType.hasPrefix("file_")
            let isImage = contentType.hasPrefix("image_")
            let sizeBytes = item["file_size_bytes"] as? Int64 ?? 0

            // Format size
            let displaySize: String
            if sizeBytes > 0 {
                if sizeBytes < 1024 {
                    displaySize = "\(sizeBytes)B"
                } else if sizeBytes < 1_048_576 {
                    displaySize = String(format: "%.1fKB", Double(sizeBytes) / 1024.0)
                } else {
                    displaySize = String(format: "%.1fMB", Double(sizeBytes) / 1048576.0)
                }
            } else {
                displaySize = ""
            }

            // Extract filename
            let metadata = item["metadata"] as? [String: Any]
            let filename = metadata?["original_filename"] as? String

            return [
                "id": (item["id"] as? NSNumber)?.stringValue ?? "",
                "contentType": contentType,
                "contentPreview": item["content_preview"] as? String ?? item["content"] as? String
                    ?? "",
                "thumbnailPath": item["thumbnail_path"] as? String ?? "",
                "deviceType": item["device_type"] as? String ?? "Unknown",
                "createdAt": item["created_at"] as? String ?? Date().toISO8601String(),
                "isEncrypted": item["is_encrypted"] as? Bool ?? false,
                "isFile": isFile,
                "isImage": isImage,
                "displaySize": displaySize,
                "filename": filename ?? "",
            ]
        }
    }
}
@available(iOS 17.0, *)
struct CopyToClipboardIntent: AppIntent {
    static var title: LocalizedStringResource = "Copy to Clipboard"

    @Parameter(title: "Clipboard ID") var clipboardId: String
    @Parameter(title: "Content") var content: String
    @Parameter(title: "Content Type") var contentType: String
    @Parameter(title: "Thumbnail Path") var thumbnailPath: String

    init() {}

    init(clipboardId: String, content: String, contentType: String, thumbnailPath: String) {
        self.clipboardId = clipboardId
        self.content = content
        self.contentType = contentType
        self.thumbnailPath = thumbnailPath
    }

    /// Copy only. Files and images are not copyable from here - they need the
    /// app to fetch and decrypt the payload first - so the widget sends those
    /// rows through a `Link` to `ghostcopy://share/<id>` instead, which
    /// SceneDelegate already handles.
    ///
    /// This used to branch on an `action` parameter and return
    /// `.result(opensIntent: OpenURLIntent(...))` for the share case. That did
    /// not compile: the two branches gave `perform()` two different opaque
    /// return types, and `OpenURLIntent` is iOS 18+ against a target of 17.
    @MainActor
    func perform() async throws -> some IntentResult {
        if contentType.lowercased().contains("image"), !thumbnailPath.isEmpty,
            let image = UIImage(contentsOfFile: thumbnailPath)
        {
            UIPasteboard.general.image = image
        } else {
            UIPasteboard.general.string = content
        }

        return .result()
    }
}

enum RefreshError: Error, LocalizedError {
    case invalidResponse
    case invalidJSON
    case missingCredentials

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Failed to fetch items from server"
        case .invalidJSON:
            return "Invalid response format from server"
        case .missingCredentials:
            return "Missing Supabase credentials"
        }
    }
}
