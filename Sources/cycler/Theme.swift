import AppKit

/// Single source of brand visuals: the fixed brand accent (so the product reads as one brand
/// regardless of the user's system accent) and the menu-bar logo.
///
enum Brand {
    /// #F2580E — Cycler's warm orange, sampled from the app icon's red→orange gradient. Deep
    /// enough that white text stays legible on a filled fill (e.g. the HUD's selected row).
    static let accent = NSColor(srgbRed: 0.949, green: 0.345, blue: 0.055, alpha: 1)

    /// The red end of the icon gradient (#FA3C28) — for accents that want the hotter hue.
    static let accentHot = NSColor(srgbRed: 0.980, green: 0.235, blue: 0.157, alpha: 1)

    /// Monochrome **template** menu-bar mark: the brand "C" glyph. Template = the system tints it
    /// (white on the dark menu bar, dark on light, highlighted when the menu is open). Loaded from
    /// the bundled MenuBarLogoTemplate (.png/@2x); falls back to a drawn glyph when running outside
    /// the app bundle (e.g. `swift run`).
    static func menuBarLogo() -> NSImage {
        if let img = Bundle.main.image(forResource: NSImage.Name("MenuBarLogoTemplate")),
           let glyph = trimmedToContent(img) {
            glyph.isTemplate = true
            // Size the trimmed glyph to fill the menu-bar height so it matches neighbouring icons
            // (the source PNG carries padding that otherwise makes the C look small).
            let height: CGFloat = 17
            let aspect = glyph.size.width / max(glyph.size.height, 1)
            glyph.size = NSSize(width: (height * aspect).rounded(), height: height)
            return glyph
        }
        return drawnMenuBarLogo()
    }

    /// Crops an image to the bounding box of its non-transparent pixels (removes padding), using
    /// the highest-resolution representation so the result stays crisp on Retina.
    private static func trimmedToContent(_ image: NSImage) -> NSImage? {
        let rep = image.representations
            .compactMap { $0 as? NSBitmapImageRep }
            .max(by: { $0.pixelsWide < $1.pixelsWide })
            ?? image.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0) }
        guard let rep, let cg = rep.cgImage else { return nil }
        let w = rep.pixelsWide, h = rep.pixelsHigh
        var minX = w, minY = h, maxX = -1, maxY = -1
        for y in 0..<h {
            for x in 0..<w where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.05 {
                if x < minX { minX = x }; if x > maxX { maxX = x }
                if y < minY { minY = y }; if y > maxY { maxY = y }
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        let crop = CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
        guard let cropped = cg.cropping(to: crop) else { return nil }
        return NSImage(cgImage: cropped, size: NSSize(width: crop.width, height: crop.height))
    }

    private static func drawnMenuBarLogo() -> NSImage {
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
