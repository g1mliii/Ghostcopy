/// Manages clipboard data shared between main app and widget extension via App Groups
/// Uses UserDefaults with App Group suite for inter-process communication
///
/// Single shared instance. The app is the only writer; the widget process
/// only ever reads.

import Foundation

// MARK: - Data Models

/// Clipboard item data structure for widget display

import WidgetKit

class WidgetDataManager {
    static let shared = WidgetDataManager()

    // App Group identifier (must match entitlements)
    private static let appGroupIdentifier = "group.com.ghostcopy.app"

    // UserDefaults keys
    private static let itemsKey = "widget_clipboard_items"
    private static let lastUpdatedKey = "widget_last_updated"
    static let lastCopiedIdKey = "widget_last_copied_id"
    static let lastCopiedAtKey = "widget_last_copied_at"
    static let appGroupSuite = appGroupIdentifier
    private static let maxItems = 5

    // Lazy-loaded shared UserDefaults
    private lazy var userDefaults =
        UserDefaults(suiteName: Self.appGroupIdentifier) ?? UserDefaults.standard

    init() {
        // Private initializer for singleton
    }

    // MARK: - Public Methods

    /// Save clipboard items to shared storage
    /// - Parameter items: Array of clipboard items (max 5)
    func saveClipboardItems(_ items: [[String: Any]]) {
        let limitedItems = Array(items.prefix(Self.maxItems))

        do {
            let jsonData = try JSONSerialization.data(withJSONObject: limitedItems)
            userDefaults.set(jsonData, forKey: Self.itemsKey)

            // Update timestamp
            userDefaults.set(Date().timeIntervalSince1970, forKey: Self.lastUpdatedKey)
            userDefaults.synchronize()

            print("[WidgetDataManager] ✅ Saved \(limitedItems.count) items to shared storage")
        } catch {
            print("[WidgetDataManager] ❌ Failed to save items: \(error)")
        }
    }

    /// Get clipboard items from shared storage
    /// - Returns: Array of clipboard items or empty array
    func getClipboardItems() -> [[String: Any]] {
        guard let jsonData = userDefaults.data(forKey: Self.itemsKey) else {
            return []
        }

        do {
            if let items = try JSONSerialization.jsonObject(with: jsonData) as? [[String: Any]] {
                return items
            }
        } catch {
            print("[WidgetDataManager] ❌ Failed to decode items: \(error)")
        }

        return []
    }

    /// Get last update timestamp
    /// - Returns: TimeInterval or nil if never updated
    func getLastUpdated() -> TimeInterval? {
        let timestamp = userDefaults.double(forKey: Self.lastUpdatedKey)
        return timestamp > 0 ? timestamp : nil
    }

    /// Filesystem path of the shared App Group container.
    ///
    /// Widget thumbnails have to live here. The widget runs in its own process
    /// with its own sandbox, so the app's Caches directory - where these were
    /// being written - is simply not readable from the extension. Every image
    /// row silently fell back to a generic icon because
    /// `UIImage(contentsOfFile:)` could not open a path it had no access to.
    func appGroupContainerPath() -> String? {
        return FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: Self.appGroupIdentifier)?
            .path
    }

    /// Clear all clipboard items from widget storage
    func clearAllItems() {
        userDefaults.removeObject(forKey: Self.itemsKey)
        userDefaults.removeObject(forKey: Self.lastUpdatedKey)
        userDefaults.synchronize()

        print("[WidgetDataManager] ✅ Cleared all widget items")
    }
}

struct ClipboardItemData: Codable {
    let id: String
    let contentType: String
    let contentPreview: String
    let thumbnailPath: String?
    let deviceType: String
    let createdAt: String
    let isEncrypted: Bool
    let isFile: Bool
    let isImage: Bool
    let displaySize: String?
    let filename: String?
    /// Staged payload in the App Group, and how to put it on the pasteboard
    /// ("text" or "image"). Both nil for clips not worth staging - a zip has no
    /// useful paste target - whose rows open the app to share instead.
    let copyPath: String?
    let copyKind: String?

    /// Convert to dictionary for UserDefaults storage
    func toDictionary() -> [String: Any] {
        return [
            "id": id,
            "contentType": contentType,
            "contentPreview": contentPreview,
            "thumbnailPath": thumbnailPath ?? "",
            "deviceType": deviceType,
            "createdAt": createdAt,
            "isEncrypted": isEncrypted,
            "isFile": isFile,
            "isImage": isImage,
            "displaySize": displaySize ?? "",
            "filename": filename ?? "",
            "copyPath": copyPath ?? "",
            "copyKind": copyKind ?? "",
        ]
    }

    /// Create from dictionary
    static func fromDictionary(_ dict: [String: Any]) -> ClipboardItemData? {
        guard let id = dict["id"] as? String,
            let contentType = dict["contentType"] as? String,
            let contentPreview = dict["contentPreview"] as? String,
            let deviceType = dict["deviceType"] as? String,
            let createdAt = dict["createdAt"] as? String
        else {
            return nil
        }

        let thumbnailPath = dict["thumbnailPath"] as? String
        let isEncrypted = dict["isEncrypted"] as? Bool ?? false
        let isFile = dict["isFile"] as? Bool ?? false
        let isImage = dict["isImage"] as? Bool ?? false
        let displaySize = dict["displaySize"] as? String
        let filename = dict["filename"] as? String
        let copyPath = dict["copyPath"] as? String
        let copyKind = dict["copyKind"] as? String

        return ClipboardItemData(
            id: id,
            contentType: contentType,
            contentPreview: contentPreview,
            thumbnailPath: thumbnailPath?.isEmpty == false ? thumbnailPath : nil,
            deviceType: deviceType,
            createdAt: createdAt,
            isEncrypted: isEncrypted,
            isFile: isFile,
            isImage: isImage,
            displaySize: displaySize,
            filename: filename,
            copyPath: copyPath?.isEmpty == false ? copyPath : nil,
            copyKind: copyKind?.isEmpty == false ? copyKind : nil
        )
    }
}
