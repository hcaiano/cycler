import AppKit

/// Single source of brand visuals: the fixed brand blue (so the product reads as one brand
/// regardless of the user's system accent) and the menu-bar logo.
///
enum Brand {
    /// #2F6BFF — the shared Caiano brand blue.
    static let blue = NSColor(srgbRed: 0.184, green: 0.420, blue: 1.0, alpha: 1)

    /// Monochrome **template** menu-bar mark: compact window outlines with a clockwise cue,
    /// matching the app icon motif. Template = the system tints it (white on the dark menu bar,
    /// dark on light, highlighted when the menu is open).
    static func menuBarLogo() -> NSImage {
        let size = NSSize(width: 18, height: 17)
        let img = NSImage(size: size, flipped: false) { rect in
            NSColor.black.setFill()
            NSColor.black.setStroke()

            let back = NSRect(x: 2.1, y: 7.5, width: 8.7, height: 5.8)
            let front = NSRect(x: 6.2, y: 4.4, width: 9.2, height: 6.6)
            let radius: CGFloat = 1.45

            let backPath = NSBezierPath(roundedRect: back, xRadius: radius, yRadius: radius)
            backPath.lineWidth = 1.5
            backPath.stroke()

            let frontPath = NSBezierPath(roundedRect: front, xRadius: radius, yRadius: radius)
            frontPath.lineWidth = 1.65
            frontPath.stroke()

            let arc = NSBezierPath()
            arc.appendArc(withCenter: NSPoint(x: 9.0, y: 8.6),
                          radius: 6.25,
                          startAngle: 204,
                          endAngle: 326,
                          clockwise: false)
            arc.lineWidth = 1.55
            arc.lineCapStyle = .round
            arc.stroke()

            let arrow = NSBezierPath()
            let tip = NSPoint(x: 14.25, y: 4.6)
            arrow.move(to: tip)
            arrow.line(to: NSPoint(x: tip.x - 2.55, y: tip.y + 0.35))
            arrow.line(to: NSPoint(x: tip.x - 1.0, y: tip.y + 2.3))
            arrow.close()
            arrow.fill()
            return true
        }
        img.isTemplate = true // tints to the menu bar (light/dark, highlighted)
        return img
    }
}
