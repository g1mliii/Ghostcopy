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
            isLoading: true,
            justCopiedId: nil
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

        // The widget is a view over what the app wrote, and the app and
        // arriving notifications are what change it. The half-hourly wake is
        // not polling - nothing is fetched, it re-renders from the App Group -
        // but without it the relative timestamps freeze, and a row claiming
        // "5h" a day later is simply wrong. This replaces the refresh button,
        // which could only ever re-draw the same pixels.
        //
        // The other reason to schedule an entry is the "Copied" confirmation. A widget renders
        // snapshots and cannot animate anything away by itself, so the
        // acknowledgement is scheduled: show it now, and a second entry a
        // couple of seconds out renders the same rows without it.
        if entry.justCopiedId != nil {
            let cleared = createEntry(
                date: Date().addingTimeInterval(Self.copiedBannerDuration),
                showingCopied: false
            )
            completion(Timeline(entries: [entry, cleared], policy: .after(Self.nextRedraw)))
        } else {
            completion(Timeline(entries: [entry], policy: .after(Self.nextRedraw)))
        }
    }

    /// How long the "Copied" confirmation stays up.
    private static let copiedBannerDuration: TimeInterval = 2

    /// Cheap enough for WidgetKit's daily budget, often enough that a
    /// timestamp is never far wrong.
    private static var nextRedraw: Date { Date().addingTimeInterval(30 * 60) }

    // MARK: - Private Methods

    /// Create widget entry from shared storage
    private func createEntry(
        date: Date = Date(),
        showingCopied: Bool = true
    ) -> ClipboardWidgetEntry {
        let dataManager = WidgetDataManager.shared

        return ClipboardWidgetEntry(
            date: date,
            items: dataManager.getClipboardItems(),
            lastUpdated: dataManager.getLastUpdated(),
            isLoading: false,
            justCopiedId: showingCopied ? recentlyCopiedId() : nil
        )
    }

    /// The clip copied within the last couple of seconds, if any.
    ///
    /// Time-bounded so a stale marker cannot leave "Copied" pinned to the
    /// widget after an unrelated reload.
    private func recentlyCopiedId() -> String? {
        guard let defaults = UserDefaults(suiteName: WidgetDataManager.appGroupSuite),
            let id = defaults.string(forKey: WidgetDataManager.lastCopiedIdKey)
        else {
            return nil
        }

        let copiedAt = defaults.double(forKey: WidgetDataManager.lastCopiedAtKey)
        guard copiedAt > 0,
            Date().timeIntervalSince1970 - copiedAt < Self.copiedBannerDuration
        else {
            return nil
        }

        return id
    }
}

/// Widget entry with clipboard data
struct ClipboardWidgetEntry: TimelineEntry {
    let date: Date
    let items: [[String: Any]]
    let lastUpdated: TimeInterval?
    let isLoading: Bool
    /// Clip copied in the last couple of seconds, shown as a confirmation.
    let justCopiedId: String?

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
