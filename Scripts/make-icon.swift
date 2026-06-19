import AppKit

// Renders a PLACEHOLDER Cycler app icon at 1024×1024 (brand-blue squircle with two overlapping
// white window panels, echoing the menu-bar mark) and writes a PNG. The final, designed icon is
// a later task — see HANDOFF.md. Usage: swift make-icon.swift out.png
let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"

let S: CGFloat = 1024
let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(S), pixelsHigh: Int(S),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext
let rgb = CGColorSpaceCreateDeviceRGB()

ctx.clear(CGRect(x: 0, y: 0, width: S, height: S))

let margin: CGFloat = 92
let body = CGRect(x: margin, y: margin, width: S - 2 * margin, height: S - 2 * margin)
let radius = body.width * 0.2237
let squircle = CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil)

// Soft drop shadow for depth.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -16),
              blur: 48, color: NSColor.black.withAlphaComponent(0.33).cgColor)
ctx.addPath(squircle)
ctx.setFillColor(NSColor.black.cgColor)
ctx.fillPath()
ctx.restoreGState()

// Clip to the squircle and paint the brand-blue gradient (bright azure -> deep blue).
ctx.saveGState()
ctx.addPath(squircle)
ctx.clip()
let bg = CGGradient(colorsSpace: rgb, colors: [
    NSColor(srgbRed: 0.157, green: 0.604, blue: 0.988, alpha: 1).cgColor, // #289AFC
    NSColor(srgbRed: 0.004, green: 0.447, blue: 0.988, alpha: 1).cgColor, // #0172FC
] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(bg,
    start: CGPoint(x: body.midX, y: body.maxY),
    end: CGPoint(x: body.midX, y: body.minY), options: [])

// Two overlapping window panels: a back one (upper-right, outlined) and a front one
// (lower-left, solid white), reading as "switch between an app's windows".
let panelW = body.width * 0.46
let panelH = body.height * 0.40
let panelR = panelW * 0.10
func panel(_ x: CGFloat, _ y: CGFloat) -> CGPath {
    CGPath(roundedRect: CGRect(x: x, y: y, width: panelW, height: panelH),
           cornerWidth: panelR, cornerHeight: panelR, transform: nil)
}
let back = panel(body.midX - panelW * 0.18, body.midY - panelH * 0.10)
let front = panel(body.midX - panelW * 0.82, body.midY - panelH * 0.55)

// Back panel: translucent white outline.
ctx.addPath(back)
ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.85).cgColor)
ctx.setLineWidth(26)
ctx.strokePath()

// Moat: punch the body blue around the front panel so the two read as separate.
ctx.saveGState()
ctx.addPath(panel(body.midX - panelW * 0.82 - 18, body.midY - panelH * 0.55 - 18))
ctx.setBlendMode(.clear)
ctx.fillPath()
ctx.restoreGState()
// Re-fill the cleared moat with the body gradient so it stays blue, not transparent.
ctx.saveGState()
ctx.addPath(panel(body.midX - panelW * 0.82 - 18, body.midY - panelH * 0.55 - 18))
ctx.clip()
ctx.drawLinearGradient(bg,
    start: CGPoint(x: body.midX, y: body.maxY),
    end: CGPoint(x: body.midX, y: body.minY), options: [])
ctx.restoreGState()

// Front panel: solid white.
ctx.addPath(front)
ctx.setFillColor(NSColor.white.cgColor)
ctx.fillPath()

ctx.restoreGState() // un-clip squircle

NSGraphicsContext.restoreGraphicsState()

guard let data = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write(Data("failed to encode PNG\n".utf8)); exit(1)
}
try! data.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath)")
