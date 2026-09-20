// Menu-bar-only apps have no bundle icon, so dialogs and notifications show a generic one unless
// we draw our own.

import Cocoa

/// Menu-bar-only apps have no bundle icon, so dialogs show a generic one; draw one instead.
func makeAppIcon() -> NSImage {
    NSImage(size: NSSize(width: 512, height: 512), flipped: false) { rect in
        let body = rect.insetBy(dx: 32, dy: 32)
        let shape = NSBezierPath(roundedRect: body, xRadius: 100, yRadius: 100)
        NSGradient(
            starting: NSColor(red: 0.42, green: 0.16, blue: 0.85, alpha: 1),
            ending: NSColor(red: 0.13, green: 0.05, blue: 0.35, alpha: 1)
        )?.draw(in: shape, angle: -90)
        let config = NSImage.SymbolConfiguration(pointSize: 260, weight: .bold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
        if let bolt = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        {
            let size = bolt.size
            bolt.draw(in: NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height))
        }
        return true
    }
}

func renderIcon(pixels: Int, to path: String) {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    makeAppIcon().draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
}
