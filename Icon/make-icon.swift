import AppKit

// Renders the Cycler app icon at 1024×1024: brand-blue squircle in the Lineup/Synclock
// family, with three window cards arranged in a clockwise cycle. Usage:
//   swift Icon/make-icon.swift Icon/icon-1024.png
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

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -16),
              blur: 48, color: NSColor.black.withAlphaComponent(0.33).cgColor)
ctx.addPath(squircle)
ctx.setFillColor(NSColor.black.cgColor)
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(squircle)
ctx.clip()

let bg = CGGradient(colorsSpace: rgb, colors: [
    NSColor(srgbRed: 0.157, green: 0.604, blue: 0.988, alpha: 1).cgColor, // #289AFC
    NSColor(srgbRed: 0.004, green: 0.447, blue: 0.988, alpha: 1).cgColor, // #0172FC
] as CFArray, locations: [0, 1])!
func paintBody() {
    ctx.drawLinearGradient(bg,
        start: CGPoint(x: body.midX, y: body.maxY),
        end: CGPoint(x: body.midX, y: body.minY), options: [])
}
paintBody()

let sheen = CGGradient(colorsSpace: rgb, colors: [
    NSColor.white.withAlphaComponent(0.18).cgColor,
    NSColor.white.withAlphaComponent(0.0).cgColor,
] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(sheen,
    start: CGPoint(x: body.midX, y: body.maxY),
    end: CGPoint(x: body.midX, y: body.midY), options: [])

func rrect(_ rect: CGRect, _ corner: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: corner, cornerHeight: corner, transform: nil)
}

func drawWindow(rect: CGRect, alpha: CGFloat, shadow: CGFloat) {
    let corner = rect.width * 0.075
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -shadow * 0.38),
                  blur: shadow,
                  color: NSColor.black.withAlphaComponent(0.18).cgColor)
    ctx.addPath(rrect(rect, corner))
    ctx.setFillColor(NSColor(srgbRed: 0.82, green: 0.92, blue: 1.0, alpha: alpha).cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    let bar = CGRect(x: rect.minX, y: rect.maxY - rect.height * 0.18,
                     width: rect.width, height: rect.height * 0.18)
    ctx.saveGState()
    ctx.addPath(rrect(rect, corner))
    ctx.clip()
    ctx.setFillColor(NSColor.white.withAlphaComponent(0.22 * alpha).cgColor)
    ctx.fill(bar)
    ctx.restoreGState()

    ctx.addPath(rrect(rect, corner))
    ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.64).cgColor)
    ctx.setLineWidth(5)
    ctx.strokePath()
}

// Three windows in a stable circular order. They overlap enough to read as "same app's
// windows", but each has a clear edge at small sizes.
let cardW = body.width * 0.45
let cardH = body.height * 0.33
let topCard = CGRect(x: body.midX - cardW * 0.36,
                     y: body.midY + body.height * 0.10,
                     width: cardW, height: cardH)
let rightCard = CGRect(x: body.midX - cardW * 0.02,
                       y: body.midY - cardH * 0.45,
                       width: cardW, height: cardH)
let leftCard = CGRect(x: body.midX - cardW * 0.74,
                      y: body.midY - cardH * 0.48,
                      width: cardW, height: cardH)

drawWindow(rect: leftCard, alpha: 0.42, shadow: 18)
drawWindow(rect: rightCard, alpha: 0.50, shadow: 20)
drawWindow(rect: topCard, alpha: 0.68, shadow: 22)

// Minimal clockwise cue: a thick open arc plus an arrow head. It stays inside the window cluster
// so the icon reads as cycling rather than just stacked documents.
let center = CGPoint(x: body.midX, y: body.midY - body.height * 0.01)
let arcRadius = body.width * 0.315
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -8),
              blur: 18, color: NSColor(srgbRed: 0, green: 0.20, blue: 0.58, alpha: 0.26).cgColor)
ctx.setLineCap(.round)
ctx.setLineJoin(.round)
ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.96).cgColor)
ctx.setLineWidth(body.width * 0.067)
ctx.addArc(center: center, radius: arcRadius,
           startAngle: CGFloat(212.0 * .pi / 180.0),
           endAngle: CGFloat(20.0 * .pi / 180.0),
           clockwise: false)
ctx.strokePath()

let tipAngle = CGFloat(20.0 * .pi / 180.0)
let tip = CGPoint(x: center.x + cos(tipAngle) * arcRadius,
                  y: center.y + sin(tipAngle) * arcRadius)
let arrow = CGMutablePath()
arrow.move(to: tip)
arrow.addLine(to: CGPoint(x: tip.x - body.width * 0.122, y: tip.y + body.width * 0.010))
arrow.addLine(to: CGPoint(x: tip.x - body.width * 0.034, y: tip.y - body.width * 0.122))
arrow.closeSubpath()
ctx.addPath(arrow)
ctx.setFillColor(NSColor.white.withAlphaComponent(0.96).cgColor)
ctx.fillPath()
ctx.restoreGState()

ctx.addPath(squircle)
ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.14).cgColor)
ctx.setLineWidth(3)
ctx.strokePath()

ctx.restoreGState()
NSGraphicsContext.restoreGraphicsState()

guard let data = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write(Data("failed to encode PNG\n".utf8)); exit(1)
}
try! data.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath)")
