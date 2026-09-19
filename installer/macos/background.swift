// Native vector artwork: no external image or font dependencies.
import AppKit

let width = 660
let height = 420
let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: width * 2, pixelsHigh: height * 2,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
)!
bitmap.size = NSSize(width: width, height: height)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
NSColor(calibratedWhite: 0.97, alpha: 1).setFill()
NSRect(x: 0, y: 0, width: width, height: height).fill()

func text(_ value: String, y: CGFloat, size: CGFloat, weight: NSFont.Weight, color: NSColor) {
    let style = NSMutableParagraphStyle()
    style.alignment = .center
    (value as NSString).draw(in: NSRect(x: 20, y: y, width: 620, height: 42), withAttributes: [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: color,
        .paragraphStyle: style,
    ])
}
text("GhostCopy", y: 332, size: 30, weight: .semibold, color: .black)
text("Drag GhostCopy into Applications", y: 292, size: 16, weight: .regular, color: .darkGray)
text("Then open GhostCopy from Applications.", y: 34, size: 13, weight: .regular, color: .darkGray)
let arrow = NSBezierPath()
arrow.move(to: NSPoint(x: 296, y: 210))
arrow.line(to: NSPoint(x: 362, y: 210))
arrow.move(to: NSPoint(x: 350, y: 222))
arrow.line(to: NSPoint(x: 362, y: 210))
arrow.line(to: NSPoint(x: 350, y: 198))
arrow.lineWidth = 2.5
arrow.lineCapStyle = .round
arrow.lineJoinStyle = .round
NSColor(calibratedRed: 0.32, green: 0.39, blue: 0.72, alpha: 1).setStroke()
arrow.stroke()
NSGraphicsContext.restoreGraphicsState()
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
