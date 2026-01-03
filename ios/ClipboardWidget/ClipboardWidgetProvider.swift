import WidgetKit
import SwiftUI

/// TimelineProvider for ClipboardWidget
/// Loads clipboard items from shared storage and provides to widget
///
/// Memory Management:
/// - Lightweight data loading (JSON parsing only)
/// - No expensive operations in getTimeline()
/// - Proper cleanup of resources in init()
struct ClipboardWidgetProvider: TimelineProvider {
    typealias Entry = ClipboardWidgetEntry

    // MARK: - TimelineProvider Methods

    /// Return placeholder while widget is loading
    func placeholder(in context: Context) -> ClipboardWidgetEntry {
        return ClipboardWidgetEntry(
            date: Date(),
            items: [],
            lastUpdated: nil,
            isLoading: true
        )
    }

    /// Get current snapshot for widget preview
    func getSnapshot(in context: Context, completion: @escaping (ClipboardWidgetEntry) -> Void) {
        let entry = createEntry()
        completion(entry)
    }

    /// Get timeline of entries for widget updates
    /// Manual refresh only - no automatic timeline updates
    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        let entry = createEntry()

        // Manual refresh only - timeline never changes automatically
        // Widget updates only via:
        // 1. User taps refresh button (triggers RefreshWidgetIntent)
        // 2. App sends data via WidgetDataManager
        // 3. FCM notification arrives (calls WidgetCenter.reloadAllTimelines)
        let timeline = Timeline(entries: [entry], policy: .never)
        completion(timeline)
    }

    // MARK: - Private Methods

    /// Create widget entry from shared storage
    private func createEntry() -> ClipboardWidgetEntry {
        let dataManager = WidgetDataManager.shared
        let items = dataManager.getClipboardItems()
        let lastUpdated = dataManager.getLastUpdated()

        return ClipboardWidgetEntry(
            date: Date(),
            items: items,
            lastUpdated: lastUpdated,
            isLoading: false
        )
    }
}

/// Widget entry with clipboard data
struct ClipboardWidgetEntry: TimelineEntry {
    let date: Date
    let items: [[String: Any]]
    let lastUpdated: TimeInterval?
    let isLoading: Bool

    /// Format last updated timestamp for display
    var formattedLastUpdated: String {
        guard let lastUpdated = lastUpdated else {
            return "Never"
        }

        let lastUpdatedDate = Date(timeIntervalSince1970: lastUpdated)
        let secondsAgo = Date().timeIntervalSince(lastUpdatedDate)

        if secondsAgo < 60 {
            return "Just now"
        } else if secondsAgo < 3600 {
            let minutesAgo = Int(secondsAgo / 60)
            return "\(minutesAgo)m ago"
        } else if secondsAgo < 86400 {
            let hoursAgo = Int(secondsAgo / 3600)
            return "\(hoursAgo)h ago"
        } else {
            let daysAgo = Int(secondsAgo / 86400)
            return "\(daysAgo)d ago"
        }
    }

    /// Extract ClipboardItemData from entry items
    var clipboardItems: [ClipboardItemData] {
        return items.compactMap { ClipboardItemData.fromDictionary($0) }
    }
}

#Preview {
    ClipboardWidgetEntry(
        date: Date(),
        items: [
            [
                "id": "1",
                "contentType": "text",
                "contentPreview": "Hello, World!",
                "thumbnailPath": nil,
                "deviceType": "iPhone",
                "createdAt": Date().addingTimeInterval(-300).toISO8601String(),
                "isEncrypted": false,
            ],
            [
                "id": "2",
                "contentType": "image",
                "contentPreview": "Image (250KB)",
                "thumbnailPath": nil,
                "deviceType": "Mac",
                "createdAt": Date().addingTimeInterval(-600).toISO8601String(),
                "isEncrypted": false,
            ],
        ],
        lastUpdated: Date().addingTimeInterval(-300).timeIntervalSince1970,
        isLoading: false
    )
    .widgetBackground(Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.05, green: 0.05, blue: 0.07, alpha: 1) : UIColor(red: 0.98, green: 0.98, blue: 0.99, alpha: 1) }))
}

// MARK: - Helper Extensions

extension Date {
    func toISO8601String() -> String {
        let formatter = ISO8601DateFormatter()
        return formatter.string(from: self)
    }
}
