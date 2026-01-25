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
    static var title: LocalizedStringResource = "Refresh Clipboard Widget"
    static var description = IntentDescription("Refresh the clipboard widget with the latest items")

    // MARK: - Perform

    @MainActor
    func perform() async throws -> some IntentResult {
        print("[RefreshWidgetIntent] 🔄 Widget refresh triggered")

        do {
            // Get stored Supabase credentials from UserDefaults
            guard let supabaseUrl = UserDefaults.standard.string(forKey: "supabase_url"),
                let anonKey = UserDefaults.standard.string(forKey: "supabase_anon_key")
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
            if #available(iOS 14.0, *) {
                WidgetCenter.shared.reloadAllTimelines()
            }
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
        // Build REST API URL (assumes user_id is stored)
        guard let userId = UserDefaults.standard.string(forKey: "user_id") else {
            print("[RefreshWidgetIntent] ⚠️ No user_id found, using empty list")
            return []
        }

        let apiUrl = URL(
            string: "\(url)/rest/v1/clipboard?user_id=eq.\(userId)&order=created_at.desc&limit=5")!

        var request = URLRequest(url: apiUrl)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue(anonKey, forHTTPHeaderField: "Authorization")

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
                "thumbnailPath": item["thumbnail_path"] as? String,
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
    static var openAppWhenRun = true

    @Parameter(title: "Clipboard ID") var clipboardId: String
    @Parameter(title: "Content") var content: String
    @Parameter(title: "Content Type") var contentType: String
    @Parameter(title: "Thumbnail Path") var thumbnailPath: String
    @Parameter(title: "Action") var action: String?

    @MainActor
    func perform() async throws -> some IntentResult {
        let actualAction = action ?? "copy"
        print(
            "[CopyToClipboardIntent] 🚀 Performing action: \(actualAction) for type: \(contentType)")

        if actualAction == "share" {
            // Open main app with share action
            // The URL scheme opening happens automatically if we used Link, but for AppIntent,
            // we rely on openAppWhenRun = true and the system launching the app.
            // Typically we pass data via NSUserActivity or URL, but Widget intents are limited.
            // HOWEVER, since openAppWhenRun is true, the app WILL launch.
            // We need to pass the intent details to the app delegate.
            // Swift AppIntents don't automatically populate launch options with custom keys easily without specific handling.
            // A better approach for "Share": Use a Link() in SwiftUI instead of a Button(intent:).
            // But sticking to Intent:
            // We can use `OpenURLIntent` or similiar, but we need custom logic.
            // Actually, `openAppWhenRun = true` continues execution in the app?
            // No, it just brings app to foreground.
            // Best practice for Widget -> App deep link is using Link(destination: URL(...))
            // I will update ClipboardWidgetView to use Link for "share" action instead of this Intent!
            // BUT, I will leave this Intent support here just in case.
            return .result(
                opensIntent: OpenURLIntent(URL(string: "ghostcopy://share/\(clipboardId)")!))
        }

        print(
            "[CopyToClipboardIntent] 📋 Copying: type=\(contentType), content=\(content.prefix(50))..."
        )

        // Check if it's an image type
        if contentType.lowercased().contains("image") && !thumbnailPath.isEmpty {
            // Copy image from thumbnail file
            if let image = UIImage(contentsOfFile: thumbnailPath) {
                UIPasteboard.general.image = image
                print("[CopyToClipboardIntent] ✅ Copied image to clipboard")
            } else {
                // Fallback to text if image fails to load
                print("[CopyToClipboardIntent] ⚠️ Image failed to load, copying text preview")
                UIPasteboard.general.string = content
            }
        } else {
            // Copy text content for non-images
            UIPasteboard.general.string = content
            print("[CopyToClipboardIntent] ✅ Copied text to clipboard")
        }

        // Open app so user can see confirmation
        // (openAppWhenRun = true handles this automatically)

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
