import WidgetKit
import SwiftUI

/// Main widget definition for iOS home screen
/// Displays last 5 clipboard items with manual refresh
///
/// Supported sizes:
/// - systemSmall: 2 items (compact view)
/// - systemMedium: 5 items (primary view)
/// - systemLarge: 5 items (expanded view with more padding)
@main
struct ClipboardWidget: Widget {
    let kind: String = "com.ghostcopy.clipboardwidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: kind,
            provider: ClipboardWidgetProvider()
        ) { entry in
            ClipboardWidgetView(entry: entry)
                .widgetBackground(
                    Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.05, green: 0.05, blue: 0.07, alpha: 1) : UIColor(red: 0.98, green: 0.98, blue: 0.99, alpha: 1) })
                )
        }
        .configurationDisplayName("Clipboard")
        .description("See your recent clipboard items")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

/// Widget bundle for future expansion
@main
struct ClipboardWidgetBundle: WidgetBundle {
    @WidgetBundleBuilder
    var body: some Widget {
        ClipboardWidget()
    }
}
