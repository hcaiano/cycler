#!/usr/bin/env bash
# Build all icon artifacts from a source PNG, normalized to a 1024x1024 master.
# Usage:
#   ./Scripts/make-icns.sh [source-icon.png] [menu-template-glyph.png]
set -euo pipefail
cd "$(dirname "$0")/.."

SOURCE="${1:-Icon/cycler-app-icon-rebuilt-1024-transparent.png}"
MENU_GLYPH="${2:-Icon/cycler-c-glyph-transparent-2026-06-23.png}"
MASTER="Icon/icon-1024.png"

if [ ! -f "$SOURCE" ]; then
  SOURCE="Icon/cycler-final-logo-1024-transparent-2026-06-23.png"
fi

echo "==> normalizing master icon from ${SOURCE}"
swift Icon/make-icon.swift "$MASTER" "$SOURCE"

WIDTH="$(sips -g pixelWidth "$MASTER" 2>/dev/null | awk '/pixelWidth/{print $2}')"
HEIGHT="$(sips -g pixelHeight "$MASTER" 2>/dev/null | awk '/pixelHeight/{print $2}')"
if [ "$WIDTH" != "1024" ] || [ "$HEIGHT" != "1024" ]; then
  echo "error: master icon must be 1024x1024, got ${WIDTH}x${HEIGHT}: $MASTER" >&2
  exit 1
fi

mkdir -p Icon Resources web/assets

ICONSET="Icon/AppIcon.iconset"
if [ -e "$ICONSET" ]; then
  command -v trash >/dev/null 2>&1 && trash "$ICONSET" || { echo "error: $ICONSET exists, trash unavailable" >&2; exit 1; }
fi
mkdir -p "$ICONSET"

# name:size pairs for the iconset (@2x = double the @1x point size)
for entry in \
  "icon_16x16:16" "icon_16x16@2x:32" \
  "icon_32x32:32" "icon_32x32@2x:64" \
  "icon_128x128:128" "icon_128x128@2x:256" \
  "icon_256x256:256" "icon_256x256@2x:512" \
  "icon_512x512:512" "icon_512x512@2x:1024"; do
  name="${entry%%:*}"; size="${entry##*:}"
  sips -z "$size" "$size" "$MASTER" --out "$ICONSET/$name.png" >/dev/null
done

iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
echo "==> wrote Resources/AppIcon.icns"

# Website/browser assets. Keep icon.png at 256x256 for the header/hero markup, and provide
# dedicated favicon/apple-touch files so the site can avoid relying on one multi-purpose asset.
sips -z 256 256 "$MASTER" --out web/assets/icon.png >/dev/null
sips -z 32 32 "$MASTER" --out web/assets/favicon.png >/dev/null
sips -z 180 180 "$MASTER" --out web/assets/apple-touch-icon.png >/dev/null

swift - "$MASTER" web/assets/og.png <<'SWIFT'
import AppKit

let sourcePath = CommandLine.arguments[1]
let outPath = CommandLine.arguments[2]
guard let icon = NSImage(contentsOfFile: sourcePath) else {
    FileHandle.standardError.write(Data("missing OG icon source\n".utf8))
    exit(1)
}

let canvas = NSSize(width: 1200, height: 630)
let image = NSImage(size: canvas, flipped: false) { rect in
    // Clean light card (matches the website); the orange lives in the icon, not the background.
    let bg = NSGradient(colors: [
        NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 1),
        NSColor(srgbRed: 0.965, green: 0.973, blue: 0.984, alpha: 1),
    ])!
    bg.draw(in: rect, angle: -90)

    let iconSize: CGFloat = 296
    let iconRect = NSRect(
        x: 110,
        y: (rect.height - iconSize) / 2,
        width: iconSize,
        height: iconSize)
    icon.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1)

    let ink = NSColor(srgbRed: 0.067, green: 0.086, blue: 0.122, alpha: 1)   // #11161f
    let muted = NSColor(srgbRed: 0.318, green: 0.357, blue: 0.416, alpha: 1) // #515b6a
    let titleAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 92, weight: .bold),
        .foregroundColor: ink,
    ]
    let bodyAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 38, weight: .medium),
        .foregroundColor: muted,
    ]
    NSString(string: "Cycler").draw(at: NSPoint(x: 470, y: 338), withAttributes: titleAttrs)
    NSString(string: "Jump to an app.").draw(at: NSPoint(x: 476, y: 276), withAttributes: bodyAttrs)
    NSString(string: "Press again to walk its windows.").draw(at: NSPoint(x: 476, y: 224), withAttributes: bodyAttrs)
    return true
}

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let data = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write(Data("failed to encode OG image\n".utf8))
    exit(1)
}
try data.write(to: URL(fileURLWithPath: outPath))
SWIFT

echo "==> wrote web icon assets"

if [ -f "$MENU_GLYPH" ]; then
  swift - "$MENU_GLYPH" Resources/MenuBarLogoTemplate.png Resources/MenuBarLogoTemplate@2x.png <<'SWIFT'
import AppKit

let glyphPath = CommandLine.arguments[1]
let oneXPath = CommandLine.arguments[2]
let twoXPath = CommandLine.arguments[3]

guard let image = NSImage(contentsOfFile: glyphPath),
      let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
      let data = cg.dataProvider?.data,
      let bytes = CFDataGetBytePtr(data) else {
    FileHandle.standardError.write(Data("failed to read menu glyph\n".utf8))
    exit(1)
}

let width = cg.width
let height = cg.height
let bpp = cg.bitsPerPixel / 8
let row = cg.bytesPerRow
let alphaInfo = cg.alphaInfo
let alphaFirst = alphaInfo == .premultipliedFirst || alphaInfo == .first || alphaInfo == .noneSkipFirst
let alphaOffset = alphaFirst ? 0 : max(0, bpp - 1)

var minX = width, minY = height, maxX = -1, maxY = -1
for y in 0..<height {
    for x in 0..<width {
        let alpha = bytes[y * row + x * bpp + alphaOffset]
        guard alpha > 12 else { continue }
        minX = min(minX, x)
        minY = min(minY, y)
        maxX = max(maxX, x)
        maxY = max(maxY, y)
    }
}

guard maxX >= minX, maxY >= minY else {
    FileHandle.standardError.write(Data("menu glyph has no visible pixels\n".utf8))
    exit(1)
}

let crop = NSRect(
    x: CGFloat(minX),
    y: CGFloat(height - maxY - 1),
    width: CGFloat(maxX - minX + 1),
    height: CGFloat(maxY - minY + 1))

func writeTemplate(width outW: CGFloat, height outH: CGFloat, to path: String) throws {
    let pad: CGFloat = outW <= 18 ? 0.4 : 0.8
    let fitW = outW - pad * 2
    let fitH = outH - pad * 2
    let scale = min(fitW / crop.width, fitH / crop.height)
    let drawSize = NSSize(width: crop.width * scale, height: crop.height * scale)
    let drawRect = NSRect(
        x: (outW - drawSize.width) / 2,
        y: (outH - drawSize.height) / 2,
        width: drawSize.width,
        height: drawSize.height)

    let output = NSImage(size: NSSize(width: outW, height: outH), flipped: false) { rect in
        NSColor.clear.setFill()
        rect.fill()
        image.draw(in: drawRect, from: crop, operation: .sourceOver, fraction: 1)
        return true
    }

    guard let tiff = output.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "MenuGlyph", code: 1)
    }
    try png.write(to: URL(fileURLWithPath: path))
}

try writeTemplate(width: 18, height: 17, to: oneXPath)
try writeTemplate(width: 36, height: 34, to: twoXPath)
SWIFT
  echo "==> wrote menu-bar template assets"
else
  echo "warning: menu glyph not found, skipped template assets: $MENU_GLYPH" >&2
fi
