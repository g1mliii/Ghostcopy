/// SwiftUI view for ClipboardWidget
/// Displays recent clipboard items with manual refresh capability
///
/// Memory Management:
/// - No expensive layout operations
/// - Images loaded from local cache only
/// - Lightweight preview text generation
import SwiftUI
import WidgetKit

struct ClipboardWidgetView: View {
    @Environment(\.widgetFamily) private var family

    var entry: ClipboardWidgetProvider.Entry

    // MARK: - Family metrics

    /// How many rows actually fit.
    ///
    /// This view used to render every item it was given at a fixed 64pt per
    /// row, whatever size the user had placed. A systemMedium widget is about
    /// 155pt tall inside its margins, so a header plus five rows came to well
    /// over twice the available height - SwiftUI centred the overflow and cut
    /// off both the header and the last rows. Nothing read widgetFamily at
    /// all, despite the doc comments claiming per-size behaviour.
    private var maxItems: Int {
        switch family {
        case .systemSmall, .systemMedium: return 2
        default: return 5
        }
    }

    private var iconSize: CGFloat {
        switch family {
        case .systemSmall: return 24
        case .systemMedium: return 30
        default: return 34
        }
    }

    private var rowPadding: CGFloat {
        switch family {
        case .systemSmall: return 6
        case .systemMedium: return 7
        default: return 9
        }
    }

    /// The small family is too narrow for a device name and a relative
    /// timestamp beside the preview text, so it shows the preview alone.
    private var showsRowDetail: Bool { family != .systemSmall }

    private var titleSize: CGFloat { family == .systemSmall ? 12 : 14 }
    private var previewSize: CGFloat { family == .systemSmall ? 11 : 12 }
    private var refreshButtonSize: CGFloat { family == .systemSmall ? 22 : 26 }

    private var accent: Color { Color(red: 0.35, green: 0.4, blue: 0.95) }

    private var tileColor: Color {
        Color(
            UIColor {
                $0.userInterfaceStyle == .dark
                    ? UIColor(red: 0.12, green: 0.12, blue: 0.16, alpha: 1)
                    : UIColor(red: 0.93, green: 0.93, blue: 0.96, alpha: 1)
            })
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            if entry.clipboardItems.isEmpty {
                emptyStateView
            } else {
                itemsListView
                // Keeps rows pinned to the top: without it a short list is
                // centred in the remaining space and drifts away from the
                // header.
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .clipped()
    }

    // MARK: - Subviews

    private var header: some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text("GhostCopy")
                    .font(.system(size: titleSize, weight: .semibold))
                    .foregroundColor(.primary)

                if family != .systemSmall {
                    Text(entry.formattedLastUpdated)
                        .font(.system(size: 10, weight: .regular))
                        .foregroundColor(.secondary)
                }
            }

            Spacer(minLength: 0)

            Button(intent: RefreshWidgetIntent()) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(accent)
                    .frame(width: refreshButtonSize, height: refreshButtonSize)
                    .background(tileColor)
                    .cornerRadius(6)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    /// Empty state when no clipboard items
    private var emptyStateView: some View {
        VStack(spacing: 8) {
            Spacer()

            Image(systemName: "doc.on.clipboard")
                .font(.system(size: family == .systemSmall ? 22 : 30, weight: .light))
                .foregroundColor(.secondary)

            Text("No clips yet")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.secondary)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// List of clipboard items
    private var itemsListView: some View {
        let items = Array(entry.clipboardItems.prefix(maxItems))

        return VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                clipboardItemRow(item)

                if index < items.count - 1 {
                    Divider()
                        .padding(.leading, 10)
                }
            }
        }
    }

    /// Individual clipboard item row.
    ///
    /// A row the app sent full text for copies in place: the intent runs inside
    /// the widget process and writes the pasteboard without GhostCopy
    /// appearing.
    ///
    /// Everything else opens the app at `ghostcopy://share/<id>`, which
    /// SceneDelegate already routes to processShareAction(). That covers files
    /// and images - the widget holds a filename and a 40px thumbnail, never the
    /// payload, and the bytes sit encrypted in R2 - and text past the size cap.
    /// A widget cannot present a share sheet itself: it has no window scene,
    /// and WidgetKit offers only Button, Toggle and Link.
    @ViewBuilder
    private func clipboardItemRow(_ item: ClipboardItemData) -> some View {
        if let copyText = item.copyText {
            Button(intent: CopyToClipboardIntent(clipboardId: item.id, content: copyText)) {
                rowContent(item)
            }
            .buttonStyle(.plain)
        } else {
            Link(destination: URL(string: "ghostcopy://share/\(item.id)")!) {
                rowContent(item)
            }
        }
    }

    /// The row's visuals, shared by both tap treatments above.
    private func rowContent(_ item: ClipboardItemData) -> some View {
        HStack(spacing: 8) {
            ZStack {
                tileColor

                // No lock branch. `isEncrypted` is true for essentially every
                // row - it describes storage, not readability - so drawing a
                // lock for it replaced the content-type icon on all of them
                // and told the user nothing.
                if let thumbnailPath = item.thumbnailPath, item.isImage,
                    let uiImage = UIImage(contentsOfFile: thumbnailPath)
                {
                    Image(uiImage: uiImage)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: iconForContentType(item.contentType))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.primary)
                }
            }
            .frame(width: iconSize, height: iconSize)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 1) {
                Text(item.isFile ? (item.filename ?? item.contentPreview) : item.contentPreview)
                    .font(.system(size: previewSize, weight: .medium))
                    .foregroundColor(.primary)
                    .lineLimit(1)

                if showsRowDetail {
                    HStack(spacing: 4) {
                        Text(item.deviceType)

                        if let size = item.displaySize, !size.isEmpty {
                            Text("\u{2022} \(size)")
                        }
                    }
                    .font(.system(size: 10, weight: .regular))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                }
            }

            Spacer(minLength: 4)

            if showsRowDetail {
                Text(formatTimestamp(item.createdAt))
                    .font(.system(size: 10, weight: .regular))
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, rowPadding)
        .contentShape(Rectangle())
    }

    // MARK: - Helper Methods

    /// Get SF Symbol for content type
    private func iconForContentType(_ type: String) -> String {
        switch type.lowercased() {
        case "image": return "photo"
        case "json": return "curlybraces"
        case "html", "markdown": return "doc.text"
        case "jwt": return "lock"
        case "color": return "rectangle.fill"
        case "file_pdf": return "doc.fill"
        case "file_zip", "file_tar", "file_gz": return "doc.zipper"
        case "file_doc", "file_docx", "file_txt": return "doc.text.fill"
        case "file_mp4": return "film.fill"
        case "file_mp3", "file_wav": return "waveform"
        default: return "doc"
        }
    }

    /// Parse an ISO-8601 instant, with or without fractional seconds.
    ///
    /// Two formatters because a single one cannot accept both: with
    /// `.withFractionalSeconds` set, a timestamp WITHOUT them fails to parse,
    /// and vice versa. Held statically so the widget does not rebuild them for
    /// every row it renders.
    private static let fractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let plainFormatter = ISO8601DateFormatter()

    private static func parseTimestamp(_ value: String) -> Date? {
        return fractionalFormatter.date(from: value)
            ?? plainFormatter.date(from: value)
    }

    /// Format ISO8601 timestamp for display
    private func formatTimestamp(_ iso8601String: String) -> String {
        // Dart's toIso8601String() always emits milliseconds
        // ("2026-09-13T12:00:00.000Z"), and ISO8601DateFormatter rejects
        // fractional seconds unless asked for them - so the default formatter
        // returned nil for every timestamp the app actually sends and the
        // widget showed "Unknown" against every clip.
        guard let date = Self.parseTimestamp(iso8601String) else {
            return "Unknown"
        }

        let secondsAgo = Date().timeIntervalSince(date)

        if secondsAgo < 60 {
            return "now"
        } else if secondsAgo < 3600 {
            return "\(Int(secondsAgo / 60))m"
        } else if secondsAgo < 86400 {
            return "\(Int(secondsAgo / 3600))h"
        } else {
            return "\(Int(secondsAgo / 86400))d"
        }
    }
}

extension View {
    func widgetBackground(_ backgroundView: some View) -> some View {
        return containerBackground(for: .widget) { backgroundView }
    }
}

#Preview(as: .systemMedium) {
    ClipboardWidget()
} timeline: {
    ClipboardWidgetEntry(
        date: Date(),
        items: [
            [
                "id": "1",
                "contentType": "text",
                "contentPreview": "Hello, World!",
                "thumbnailPath": "",
                "deviceType": "iPhone",
                "createdAt": Date().addingTimeInterval(-300).toISO8601String(),
                "isEncrypted": false,
            ],
            [
                "id": "2",
                "contentType": "image",
                "contentPreview": "Image (250KB)",
                "thumbnailPath": "",
                "deviceType": "Mac",
                "createdAt": Date().addingTimeInterval(-600).toISO8601String(),
                "isEncrypted": false,
            ],
            [
                "id": "3",
                "contentType": "json",
                "contentPreview": "{\"name\": \"John\", \"age\": 30}",
                "thumbnailPath": "",
                "deviceType": "iPad",
                "createdAt": Date().addingTimeInterval(-1200).toISO8601String(),
                "isEncrypted": false,
            ],
        ],
        lastUpdated: Date().addingTimeInterval(-300).timeIntervalSince1970,
        isLoading: false
    )
}
