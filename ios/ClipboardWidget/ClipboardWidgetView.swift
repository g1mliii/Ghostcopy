import SwiftUI
import WidgetKit

/// SwiftUI view for ClipboardWidget
/// Displays last 5 clipboard items with manual refresh capability
///
/// Memory Management:
/// - No expensive layout operations
/// - Images loaded from local cache only
/// - Lightweight preview text generation
struct ClipboardWidgetView: View {
    var entry: ClipboardWidgetProvider.Entry

    var body: some View {
        ZStack {
            // Background
            Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.05, green: 0.05, blue: 0.07, alpha: 1) : UIColor(red: 0.98, green: 0.98, blue: 0.99, alpha: 1) })
                .ignoresSafeArea()

            VStack(spacing: 0) {
                // Header with refresh button
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("GhostCopy")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.primary)

                        Text(entry.formattedLastUpdated)
                            .font(.system(size: 11, weight: .regular))
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    // Refresh button
                    Button(intent: RefreshWidgetIntent()) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(Color(red: 0.35, green: 0.4, blue: 0.95))
                            .frame(width: 28, height: 28)
                            .background(
                                Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.12, green: 0.12, blue: 0.16, alpha: 1) : UIColor(red: 0.93, green: 0.93, blue: 0.96, alpha: 1) })
                            )
                            .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                }
                .padding(12)

                Divider()
                    .padding(.horizontal, 12)

                // Clipboard items list
                if entry.items.isEmpty {
                    emptyStateView
                } else {
                    itemsListView
                }
            }
        }
    }

    // MARK: - Subviews

    /// Empty state when no clipboard items
    private var emptyStateView: some View {
        VStack(spacing: 12) {
            Spacer()

            Image(systemName: "doc.on.clipboard")
                .font(.system(size: 32, weight: .light))
                .foregroundColor(.secondary)

            Text("No clips yet")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.secondary)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// List of clipboard items
    private var itemsListView: some View {
        VStack(spacing: 0) {
            ForEach(Array(entry.clipboardItems.enumerated()), id: \.element.id) { index, item in
                clipboardItemRow(item)

                if index < entry.clipboardItems.count - 1 {
                    Divider()
                        .padding(.horizontal, 12)
                }
            }
        }
    }

    /// Individual clipboard item row
    private func clipboardItemRow(_ item: ClipboardItemData) -> some View {
        Button(intent: CopyToClipboardIntent(
            clipboardId: item.id,
            content: item.contentPreview,
            contentType: item.contentType,
            thumbnailPath: item.thumbnailPath ?? ""
        )) {
            HStack(spacing: 10) {
                // Icon or thumbnail
                ZStack {
                    Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.12, green: 0.12, blue: 0.16, alpha: 1) : UIColor(red: 0.93, green: 0.93, blue: 0.96, alpha: 1) })

                    if item.isEncrypted {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(Color(red: 0.35, green: 0.4, blue: 0.95))
                    } else if let thumbnailPath = item.thumbnailPath, item.contentType.lowercased().contains("image") {
                        // Display actual image thumbnail for images
                        if let uiImage = UIImage(contentsOfFile: thumbnailPath) {
                            Image(uiImage: uiImage)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 40, height: 40)
                                .clipped()
                        } else {
                            // Fallback to icon if image fails to load
                            Image(systemName: "photo")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(.primary)
                        }
                    } else {
                        // Show icon for non-image types
                        Image(systemName: iconForContentType(item.contentType))
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.primary)
                    }
                }
                .frame(width: 40, height: 40)
                .cornerRadius(6)

                // Content preview
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.contentPreview)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.primary)
                        .lineLimit(1)

                    Text(item.deviceType)
                        .font(.system(size: 10, weight: .regular))
                        .foregroundColor(.secondary)
                }

                Spacer()

                // Timestamp
                Text(formatTimestamp(item.createdAt))
                    .font(.system(size: 10, weight: .regular))
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Helper Methods

    /// Get SF Symbol for content type
    private func iconForContentType(_ type: String) -> String {
        switch type.lowercased() {
        case "image":
            return "photo"
        case "json":
            return "curlybraces"
        case "html", "markdown":
            return "doc.text"
        case "jwt":
            return "lock"
        case "color":
            return "rectangle.fill"
        default:
            return "doc"
        }
    }

    /// Format ISO8601 timestamp for display
    private func formatTimestamp(_ iso8601String: String) -> String {
        let formatter = ISO8601DateFormatter()
        guard let date = formatter.date(from: iso8601String) else {
            return "Unknown"
        }

        let secondsAgo = Date().timeIntervalSince(date)

        if secondsAgo < 60 {
            return "now"
        } else if secondsAgo < 3600 {
            let minutesAgo = Int(secondsAgo / 60)
            return "\(minutesAgo)m"
        } else if secondsAgo < 86400 {
            let hoursAgo = Int(secondsAgo / 3600)
            return "\(hoursAgo)h"
        } else {
            let daysAgo = Int(secondsAgo / 86400)
            return "\(daysAgo)d"
        }
    }
}

// MARK: - Widget Extensions

extension View {
    func widgetBackground(_ backgroundView: some View) -> some View {
        if #available(iOS 17.0, *) {
            return AnyView(
                self.containerBackground(for: .widget) {
                    backgroundView
                }
            )
        } else {
            return AnyView(self.background(backgroundView))
        }
    }
}

// MARK: - Preview

#Preview(as: .systemSmall) {
    ClipboardWidget()
} timeline: {
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
            [
                "id": "3",
                "contentType": "json",
                "contentPreview": "{\"name\": \"John\", \"age\": 30}",
                "thumbnailPath": nil,
                "deviceType": "iPad",
                "createdAt": Date().addingTimeInterval(-1200).toISO8601String(),
                "isEncrypted": false,
            ],
        ],
        lastUpdated: Date().addingTimeInterval(-300).timeIntervalSince1970,
        isLoading: false
    )
}
