#!/bin/bash
set -e

APP="PDF Layout.app"
BUNDLE="$APP/Contents"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "Building PDF Layout..."

# Create bundle structure
mkdir -p "$BUNDLE/MacOS" "$BUNDLE/Resources"

# Compile
swiftc -O -o "$BUNDLE/MacOS/PDFLayout" "$SCRIPT_DIR/pdflayout.swift" \
    -framework AppKit -framework UniformTypeIdentifiers -framework PDFKit

# Info.plist
cat > "$BUNDLE/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>PDF Layout</string>
    <key>CFBundleDisplayName</key>
    <string>PDF Layout</string>
    <key>CFBundleIdentifier</key>
    <string>com.local.pdflayout</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleExecutable</key>
    <string>PDFLayout</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
</dict>
</plist>
PLIST

# Generate icon
ICONSET=$(mktemp -d)/AppIcon.iconset
mkdir -p "$ICONSET"

ICON_SWIFT=$(mktemp).swift
cat > "$ICON_SWIFT" << 'ICONSWIFT'
import AppKit

let dir = CommandLine.arguments[1]
let sizes: [(CGFloat, String)] = [
    (16,"icon_16x16"),(32,"icon_16x16@2x"),(32,"icon_32x32"),(64,"icon_32x32@2x"),
    (128,"icon_128x128"),(256,"icon_128x128@2x"),(256,"icon_256x256"),(512,"icon_256x256@2x"),
    (512,"icon_512x512"),(1024,"icon_512x512@2x"),
]

for (sz, name) in sizes {
    let img = NSImage(size: NSSize(width: sz, height: sz))
    img.lockFocus()
    guard let ctx = NSGraphicsContext.current?.cgContext else { img.unlockFocus(); continue }
    let r = NSRect(x: 0, y: 0, width: sz, height: sz)
    let inset = sz * 0.03
    let rad = sz * 0.22
    let bgRect = r.insetBy(dx: inset, dy: inset)

    // ── Background: glass gradient (deep indigo → rich blue) ──
    let bgPath = NSBezierPath(roundedRect: bgRect, xRadius: rad, yRadius: rad)
    ctx.saveGState()
    bgPath.addClip()
    let bgColors = [
        NSColor(red: 0.16, green: 0.12, blue: 0.36, alpha: 1).cgColor,
        NSColor(red: 0.10, green: 0.18, blue: 0.42, alpha: 1).cgColor,
        NSColor(red: 0.08, green: 0.22, blue: 0.50, alpha: 1).cgColor,
    ] as CFArray
    if let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                              colors: bgColors, locations: [0, 0.5, 1]) {
        ctx.drawLinearGradient(grad,
            start: CGPoint(x: bgRect.minX, y: bgRect.maxY),
            end: CGPoint(x: bgRect.maxX, y: bgRect.minY), options: [])
    }

    // ── Glass highlight: subtle top sheen ──
    let sheenRect = NSRect(x: bgRect.minX, y: bgRect.midY, width: bgRect.width, height: bgRect.height * 0.5)
    let sheenColors = [
        NSColor.white.withAlphaComponent(0.12).cgColor,
        NSColor.white.withAlphaComponent(0.0).cgColor,
    ] as CFArray
    if let sheen = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                               colors: sheenColors, locations: [0, 1]) {
        ctx.drawLinearGradient(sheen,
            start: CGPoint(x: sheenRect.midX, y: sheenRect.maxY),
            end: CGPoint(x: sheenRect.midX, y: sheenRect.minY), options: [])
    }
    ctx.restoreGState()

    // ── Border: thin luminous edge ──
    NSColor.white.withAlphaComponent(0.18).setStroke()
    bgPath.lineWidth = sz * 0.006
    bgPath.stroke()

    // ── Back page (slightly offset, translucent) ──
    let pw = sz * 0.38, ph = pw * 1.38
    let cx = sz / 2, cy = sz / 2 + sz * 0.01
    let backX = cx - pw / 2 + sz * 0.03
    let backY = cy - ph / 2 - sz * 0.02
    let backRect = NSRect(x: backX, y: backY, width: pw, height: ph)
    let backRad = sz * 0.03
    let backPath = NSBezierPath(roundedRect: backRect, xRadius: backRad, yRadius: backRad)
    NSGraphicsContext.saveGraphicsState()
    let bs = NSShadow(); bs.shadowColor = NSColor.black.withAlphaComponent(0.25)
    bs.shadowOffset = NSSize(width: sz * 0.005, height: -sz * 0.01)
    bs.shadowBlurRadius = sz * 0.025; bs.set()
    NSColor.white.withAlphaComponent(0.35).setFill(); backPath.fill()
    NSGraphicsContext.restoreGraphicsState()

    // ── Front page (main, white with glass feel) ──
    let frontX = cx - pw / 2 - sz * 0.02
    let frontY = cy - ph / 2 + sz * 0.02
    let frontRect = NSRect(x: frontX, y: frontY, width: pw, height: ph)
    let frontPath = NSBezierPath(roundedRect: frontRect, xRadius: backRad, yRadius: backRad)
    NSGraphicsContext.saveGraphicsState()
    let fs = NSShadow(); fs.shadowColor = NSColor.black.withAlphaComponent(0.4)
    fs.shadowOffset = NSSize(width: -sz * 0.005, height: -sz * 0.02)
    fs.shadowBlurRadius = sz * 0.05; fs.set()
    NSColor.white.withAlphaComponent(0.92).setFill(); frontPath.fill()
    NSGraphicsContext.restoreGraphicsState()
    // Page inner sheen
    ctx.saveGState()
    frontPath.addClip()
    let pageSheen = [
        NSColor.white.withAlphaComponent(0.5).cgColor,
        NSColor.white.withAlphaComponent(0.0).cgColor,
    ] as CFArray
    if let pg = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                            colors: pageSheen, locations: [0, 1]) {
        ctx.drawLinearGradient(pg,
            start: CGPoint(x: frontRect.minX, y: frontRect.maxY),
            end: CGPoint(x: frontRect.maxX, y: frontRect.midY), options: [])
    }
    ctx.restoreGState()

    // ── Layout elements on front page ──
    let pm = sz * 0.035  // page margin
    let elX = frontX + pm, elW = pw - pm * 2

    // Teal image block (top)
    let tealH = ph * 0.28
    let tealY = frontY + ph - pm - tealH
    let tealRect = NSRect(x: elX, y: tealY, width: elW, height: tealH)
    let tealPath = NSBezierPath(roundedRect: tealRect, xRadius: sz * 0.015, yRadius: sz * 0.015)
    ctx.saveGState()
    tealPath.addClip()
    let tealColors = [
        NSColor(red: 0.15, green: 0.78, blue: 0.72, alpha: 0.9).cgColor,
        NSColor(red: 0.10, green: 0.60, blue: 0.65, alpha: 0.9).cgColor,
    ] as CFArray
    if let tg = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                            colors: tealColors, locations: [0, 1]) {
        ctx.drawLinearGradient(tg,
            start: CGPoint(x: tealRect.minX, y: tealRect.maxY),
            end: CGPoint(x: tealRect.maxX, y: tealRect.minY), options: [])
    }
    ctx.restoreGState()

    // Orange accent block (middle-left)
    let gap = sz * 0.02
    let orangeH = ph * 0.18
    let orangeW = elW * 0.55
    let orangeY = tealY - gap - orangeH
    let orangeRect = NSRect(x: elX, y: orangeY, width: orangeW, height: orangeH)
    let orangePath = NSBezierPath(roundedRect: orangeRect, xRadius: sz * 0.012, yRadius: sz * 0.012)
    ctx.saveGState()
    orangePath.addClip()
    let orangeColors = [
        NSColor(red: 1.0, green: 0.62, blue: 0.25, alpha: 0.85).cgColor,
        NSColor(red: 0.95, green: 0.45, blue: 0.20, alpha: 0.85).cgColor,
    ] as CFArray
    if let og = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                            colors: orangeColors, locations: [0, 1]) {
        ctx.drawLinearGradient(og,
            start: CGPoint(x: orangeRect.minX, y: orangeRect.maxY),
            end: CGPoint(x: orangeRect.maxX, y: orangeRect.minY), options: [])
    }
    ctx.restoreGState()

    // Text lines (bottom area)
    let lineH = sz * 0.012
    let lineGap = sz * 0.018
    var lineY = orangeY - gap - lineH
    for i in 0..<3 {
        let lw = i == 2 ? elW * 0.6 : elW
        let lineRect = NSRect(x: elX, y: lineY, width: lw, height: lineH)
        NSColor(red: 0.55, green: 0.55, blue: 0.62, alpha: 0.3).setFill()
        NSBezierPath(roundedRect: lineRect, xRadius: lineH/2, yRadius: lineH/2).fill()
        lineY -= lineH + lineGap
    }

    // ── "PDF" label at bottom ──
    let labelSz2 = sz * 0.11
    let labelFont = NSFont.systemFont(ofSize: labelSz2, weight: .heavy)
    let labelAttrs: [NSAttributedString.Key: Any] = [
        .font: labelFont,
        .foregroundColor: NSColor(red: 0.22, green: 0.82, blue: 0.75, alpha: 1),
    ]
    let label = "PDF" as NSString
    let labelSize = label.size(withAttributes: labelAttrs)
    let labelX = (sz - labelSize.width) / 2
    let labelY = frontY - labelSize.height - sz * 0.025
    // Glow behind text
    NSGraphicsContext.saveGraphicsState()
    let glow = NSShadow(); glow.shadowColor = NSColor(red: 0.15, green: 0.70, blue: 0.65, alpha: 0.6)
    glow.shadowOffset = .zero; glow.shadowBlurRadius = sz * 0.04; glow.set()
    label.draw(at: NSPoint(x: labelX, y: labelY), withAttributes: labelAttrs)
    NSGraphicsContext.restoreGraphicsState()
    label.draw(at: NSPoint(x: labelX, y: labelY), withAttributes: labelAttrs)

    img.unlockFocus()
    guard let t = img.tiffRepresentation, let rep = NSBitmapImageRep(data: t),
          let png = rep.representation(using: .png, properties: [:]) else { continue }
    try? png.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
}
ICONSWIFT

swiftc -o "${ICON_SWIFT%.swift}" "$ICON_SWIFT" -framework AppKit 2>/dev/null
"${ICON_SWIFT%.swift}" "$ICONSET"
iconutil -c icns "$ICONSET" -o "$BUNDLE/Resources/AppIcon.icns"
rm -rf "$(dirname "$ICONSET")" "$ICON_SWIFT" "${ICON_SWIFT%.swift}"

touch "$APP"

echo ""
echo "Done! Built: $APP"
echo "Move it to /Applications or double-click to run."
