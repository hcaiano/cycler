import AppKit

/// Single source of brand visuals: the fixed brand blue (so the product reads as one brand
/// regardless of the user's system accent) and the menu-bar logo.
///
/// NOTE: this is a placeholder menu-bar mark for the scaffold. The real Cycler icon set
/// (app .icns + a tuned template menu-bar glyph) is a design task for later — see HANDOFF.md.
enum Brand {
    /// #2F6BFF — the shared Caiano brand blue.
    static let blue = NSColor(srgbRed: 0.184, green: 0.420, blue: 1.0, alpha: 1)

    /// Monochrome **template** menu-bar mark: two overlapping window rectangles, evoking
    /// "switch between an app's windows". Template = the system tints it (white on the dark
    /// menu bar, dark on light, highlighted when the menu is open). Solid fills so it reads
    /// at ~18 pt.
    static func menuBarLogo() -> NSImage {
        let size = NSSize(width: 18, height: 16)
        let img = NSImage(size: size, flipped: false) { rect in
            let box = rect.insetBy(dx: 1.5, dy: 1.5)
            let w = box.width * 0.66
            let h = box.height * 0.66
            let radius: CGFloat = 2.2
            // Back window: upper-right. Front window: lower-left, overlapping it.
            let back = NSRect(x: box.maxX - w, y: box.maxY - h, width: w, height: h)
            let front = NSRect(x: box.minX, y: box.minY, width: w, height: h)

            // Punch a gap around the front window so the two read as separate panes even when
            // tinted a single colour: stroke the back one, then knock out behind the front.
            NSColor.black.setStroke()
            let backPath = NSBezierPath(roundedRect: back, xRadius: radius, yRadius: radius)
            backPath.lineWidth = 1.6
            backPath.stroke()

            // Clear a 1px-ish moat behind the front window, then fill the front window solid.
            NSGraphicsContext.current?.compositingOperation = .clear
            NSBezierPath(roundedRect: front.insetBy(dx: -1.2, dy: -1.2), xRadius: radius, yRadius: radius).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            NSColor.black.setFill()
            NSBezierPath(roundedRect: front, xRadius: radius, yRadius: radius).fill()
            return true
        }
        img.isTemplate = true // tints to the menu bar (light/dark, highlighted)
        return img
    }
}
