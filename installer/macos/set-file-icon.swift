// Finder's custom file icon is local metadata; HTTP downloads may discard it.
import AppKit

let iconPath = CommandLine.arguments[1]
let filePath = CommandLine.arguments[2]
guard let icon = NSImage(contentsOfFile: iconPath),
      NSWorkspace.shared.setIcon(icon, forFile: filePath, options: []) else {
  fputs("Could not set the GhostCopy icon on \(filePath)\n", stderr)
  exit(1)
}
