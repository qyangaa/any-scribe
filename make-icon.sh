#!/bin/bash
# Render the Any Scribe app icon → Resources/AppIcon.icns (committed; package-app.sh embeds it).
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p Resources
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

cat > "${TMP}/render.swift" <<'SWIFT'
import AppKit

let size: CGFloat = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// Rounded-rect tile with a diagonal indigo→violet gradient.
let margin = size * 0.098
let rect = NSRect(x: margin, y: margin, width: size - 2*margin, height: size - 2*margin)
let radius = rect.width * 0.2237
let tile = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
let grad = NSGradient(starting: NSColor(srgbRed: 0.56, green: 0.49, blue: 1.00, alpha: 1),
                      ending:   NSColor(srgbRed: 0.27, green: 0.19, blue: 0.82, alpha: 1))!
grad.draw(in: tile, angle: -90)

// Centered audio waveform; the tallest bar is red to echo the recording indicator.
let heights: [CGFloat] = [0.30, 0.55, 0.80, 1.0, 0.72, 0.48, 0.30]
let redIndex = 3
let barW = size * 0.066
let gap  = size * 0.040
let n = CGFloat(heights.count)
let totalW = n*barW + (n-1)*gap
var x = (size - totalW) / 2
let maxH = rect.height * 0.54
for (i, h) in heights.enumerated() {
    let bh = maxH * h
    let bar = NSRect(x: x, y: size/2 - bh/2, width: barW, height: bh)
    (i == redIndex ? NSColor(srgbRed: 1.0, green: 0.29, blue: 0.33, alpha: 1) : NSColor.white).setFill()
    NSBezierPath(roundedRect: bar, xRadius: barW/2, yRadius: barW/2).fill()
    x += barW + gap
}

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
SWIFT

swift "${TMP}/render.swift" "${TMP}/icon_1024.png"

ICONSET="${TMP}/AppIcon.iconset"
mkdir -p "${ICONSET}"
for s in 16 32 128 256 512; do
    sips -z $s $s "${TMP}/icon_1024.png" --out "${ICONSET}/icon_${s}x${s}.png" >/dev/null
    d=$((s*2)); sips -z $d $d "${TMP}/icon_1024.png" --out "${ICONSET}/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "${ICONSET}" -o Resources/AppIcon.icns
echo "✓ Resources/AppIcon.icns ($(du -h Resources/AppIcon.icns | cut -f1))"
