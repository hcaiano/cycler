import AppKit

// Produces the 1024x1024 macOS app-icon master from the canonical Cycler artwork.
//
// The supplied artwork is already a finished icon (a gradient rounded-rect "squircle" with the
// white C, on transparency). We simply scale it to fill the 1024 canvas — no cropping, no padding,
// no halo removal — so the icon fills its cell the way stock macOS app icons do.
//
// Usage:
//   swift Icon/make-icon.swift Icon/icon-1024.png [source.png]
let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Icon/icon-1024.png"
let defaultSource = "Icon/cycler-final-logo-1024-transparent-2026-06-23.png"
let sourcePath = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : defaultSource

guard let source = NSImage(contentsOfFile: sourcePath) else {
    FileHandle.standardError.write(Data("missing or unreadable icon source: \(sourcePath)\n".utf8))
    exit(1)
}

let canvas = NSSize(width: 1024, height: 1024)
let image = NSImage(size: canvas, flipped: false) { rect in
    NSColor.clear.setFill()
    rect.fill()
    source.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
    return true
}

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let data = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write(Data("failed to encode icon PNG\n".utf8))
    exit(1)
}

try data.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath) (1024x1024, scaled to fill)")
