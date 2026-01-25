/// Manages clipboard data shared between main app and widget extension via App Groups
/// Uses UserDefaults with App Group suite for inter-process communication
///
/// Memory Management:
/// - Weak references for delegates (prevents retain cycles)
/// - Single shared instance (singleton)
/// - Properly cleans up UserDefaults observers on deinit

import Foundation

// MARK: - Data Models

/// Clipboard item data structure for widget display

// MARK: - Delegate Protocol

/// Delegate for widget update notifications
import WidgetKit

class WidgetDataManager {
    static let shared = WidgetDataManager()

    // App Group identifier (must match entitlements)
    private static let appGroupIdentifier = "group.com.ghostcopy.app"

    // UserDefaults keys
    private static let itemsKey = "widget_clipboard_items"
    private static let lastUpdatedKey = "widget_last_updated"
    private static let maxItems = 5

    // Lazy-loaded shared UserDefaults
    private lazy var userDefaults =
        UserDefaults(suiteName: Self.appGroupIdentifier) ?? UserDefaults.standard

    // Keep track of changes for widget reload
    private weak var widgetUpdateDelegate: WidgetUpdateDelegate?

    init() {
        // Private initializer for singleton
    }

    // MARK: - Public Methods

    /// Set delegate for widget update notifications
    /// Uses weak reference to prevent retain cycles
    func setWidgetUpdateDelegate(_ delegate: WidgetUpdateDelegate?) {
        self.widgetUpdateDelegate = delegate
    }

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

    /// Add new clipboard item at the beginning of the list
    /// Used when FCM notification arrives or app receives new clipboard item
    /// - Parameter item: Clipboard item dictionary
    func addNewClip(_ item: [String: Any]) {
        var items = getClipboardItems()
        items.insert(item, at: 0)
        saveClipboardItems(items)

        // Notify widget to reload
        notifyWidgetUpdate()
    }

    /// Clear all clipboard items from widget storage
    func clearAllItems() {
        userDefaults.removeObject(forKey: Self.itemsKey)
        userDefaults.removeObject(forKey: Self.lastUpdatedKey)
        userDefaults.synchronize()

        print("[WidgetDataManager] ✅ Cleared all widget items")
    }

    // MARK: - Private Methods

    /// Notify widget to reload data
    /// This triggers the widget's TimelineProvider to refresh
    private func notifyWidgetUpdate() {
        widgetUpdateDelegate?.onWidgetDataUpdated()

        #if !targetEnvironment(simulator)
            // On physical device, request widget refresh from system
            if #available(iOS 14.0, *) {
                WidgetCenter.shared.reloadAllTimelines()
            }
        #endif
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
            filename: filename
        )
    }
}
protocol WidgetUpdateDelegate: AnyObject {
    func onWidgetDataUpdated()
}
