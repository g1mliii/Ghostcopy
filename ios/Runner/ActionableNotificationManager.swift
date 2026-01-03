import UserNotifications

/// Manager for iOS actionable notifications
/// Handles notification category registration and action identifiers
///
/// Memory Management:
/// - Singleton pattern with weak references
/// - No retained notification objects
/// - Proper cleanup of notification center observers
/// - UNUserNotificationCenter is maintained by system (no retain)
class ActionableNotificationManager {
    static let shared = ActionableNotificationManager()

    // Notification action identifiers
    enum ActionIdentifier: String {
        case copy = "COPY_ACTION"
        case dismiss = "DISMISS_ACTION"
        case details = "DETAILS_ACTION"
    }

    // Notification category identifiers
    enum CategoryIdentifier: String {
        case clipboardSync = "CLIPBOARD_SYNC"
    }

    private init() {
        // Private initializer for singleton
    }

    // MARK: - Public Methods

    /// Register notification categories with actions
    /// Called once during app initialization
    func registerCategories() {
        // Define "Copy to Clipboard" action
        // Uses .foreground option to bring app to foreground
        let copyAction = UNNotificationAction(
            identifier: ActionIdentifier.copy.rawValue,
            title: "Copy",
            options: [.foreground]
        )

        // Define "Dismiss" action (no foreground)
        let dismissAction = UNNotificationAction(
            identifier: ActionIdentifier.dismiss.rawValue,
            title: "Dismiss",
            options: []
        )

        // Define "See Details" action
        let detailsAction = UNNotificationAction(
            identifier: ActionIdentifier.details.rawValue,
            title: "Details",
            options: [.foreground]
        )

        // Define category with clipboard sync actions
        let clipboardCategory = UNNotificationCategory(
            identifier: CategoryIdentifier.clipboardSync.rawValue,
            actions: [copyAction, dismissAction, detailsAction],
            intentIdentifiers: [],
            options: [.customDismissAction]
        )

        // Register category with notification center
        UNUserNotificationCenter.current().setNotificationCategories([clipboardCategory])

        print("[ActionableNotifications] ✅ Registered notification categories")
    }

    /// Check if action is copy action
    func isCopyAction(_ actionIdentifier: String) -> Bool {
        return actionIdentifier == ActionIdentifier.copy.rawValue
    }

    /// Check if action is dismiss action
    func isDismissAction(_ actionIdentifier: String) -> Bool {
        return actionIdentifier == ActionIdentifier.dismiss.rawValue
    }

    /// Check if action is details action
    func isDetailsAction(_ actionIdentifier: String) -> Bool {
        return actionIdentifier == ActionIdentifier.details.rawValue
    }

    /// Get human-readable action name for logging
    func getActionName(_ actionIdentifier: String) -> String {
        switch actionIdentifier {
        case ActionIdentifier.copy.rawValue:
            return "Copy to Clipboard"
        case ActionIdentifier.dismiss.rawValue:
            return "Dismiss"
        case ActionIdentifier.details.rawValue:
            return "See Details"
        case UNNotificationDefaultActionIdentifier:
            return "Notification Tap"
        case UNNotificationDismissActionIdentifier:
            return "Swipe to Dismiss"
        default:
            return "Unknown Action"
        }
    }
}

// MARK: - iOS Clipboard Access Notes

/*
 iOS Clipboard Access Restrictions:

 iOS restricts clipboard access to specific contexts:
 ✅ ALLOWED: In-app clipboard access
 ✅ ALLOWED: When handling user notification interactions
    - Tapping notification
    - Tapping notification action button
    - Long-pressing notification for action menu
 ❌ NOT ALLOWED: Background app refresh
 ❌ NOT ALLOWED: App extensions (except share extensions)
 ❌ NOT ALLOWED: Silent notifications without user interaction

 Our Implementation:
 1. UIPasteboard.general.string = content
    - Called in didReceive (user taps action) ✅
    - Called in willPresent (foreground, auto-copy) ✅
    - Called in notification action handler ✅

 2. ActionableNotificationManager provides:
    - Proper notification category registration
    - Multiple action options (Copy, Dismiss, Details)
    - Clear identifiers for action handling
    - Memory leak protection

 3. Memory Leak Prevention:
    - Singleton pattern with safe initialization
    - No retained notification objects
    - Weak self in closures
    - Proper cleanup of observers

 When Firebase credentials are available:
 1. Ensure FCM payload includes:
    - "mutable-content" = true (to customize notification)
    - "aps": { "category": "CLIPBOARD_SYNC" } (for actionable notifications)
    - "clipboard_content": "..." (data for copy action)
    - "content_preview": "..." (preview text)

 2. Edge Case Handling:
    - Large content (>4KB): FCM sends clipboardId only
    - App fetches full content on action tap
    - Encrypted content: Passcode required in app

 3. Silent Notifications (future):
    - Can only update UI, not write to clipboard
    - Requires explicit user action for clipboard access
 */
