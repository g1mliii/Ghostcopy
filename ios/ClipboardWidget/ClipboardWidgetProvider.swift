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
        // The widget is a view over what the app wrote, and the app and
        // arriving notifications are what change it. The half-hourly wake is
        // not polling - nothing is fetched, it re-renders from the App Group -
        // but without it the relative timestamps freeze, and a row claiming
        // "5h" a day later is simply wrong.
        completion(Timeline(entries: [createEntry()], policy: .after(Self.nextRedraw)))
    }

    /// Cheap enough for WidgetKit's daily budget, often enough that a
    /// timestamp is never far wrong.
    private static var nextRedraw: Date { Date().addingTimeInterval(30 * 60) }

    // MARK: - Private Methods

    /// Create widget entry from shared storage
    private func createEntry() -> ClipboardWidgetEntry {
        let dataManager = WidgetDataManager.shared

        return ClipboardWidgetEntry(
            date: Date(),
            items: dataManager.getClipboardItems(),
            lastUpdated: dataManager.getLastUpdated(),
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

// MARK: - Helper Extensions

extension Date {
    func toISO8601String() -> String {
        let formatter = ISO8601DateFormatter()
        return formatter.string(from: self)
    }
}
