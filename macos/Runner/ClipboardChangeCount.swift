import Cocoa
import FlutterMacOS

/// Exposes NSPasteboard's change counter to Dart.
///
/// The auto-send monitor used to read the whole clipboard every five seconds
/// to hash it, which meant re-reading a copied file or image - up to the 10MB
/// limit - from disk on every tick just to learn nothing had changed. The
/// change counter is a single integer that AppKit bumps on every write, so the
/// expensive read only happens when there is actually something new.
class ClipboardChangeCount {
    private let channel: FlutterMethodChannel

    init(messenger: FlutterBinaryMessenger) {
        channel = FlutterMethodChannel(
            name: "com.ghostcopy.app/clipboard_change",
            binaryMessenger: messenger
        )
        channel.setMethodCallHandler { (call, result) in
            if call.method == "changeCount" {
                result(NSPasteboard.general.changeCount)
            } else {
                result(FlutterMethodNotImplemented)
            }
        }
    }
}
