// Renders the 1024 px app icon. Usage: swift scripts/make-icon.swift <out.png>
import AppKit

let out = CommandLine.arguments.dropFirst().first ?? "icon-1024.png"
let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))

image.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext

// macOS icon grid: 824 px body centred on the 1024 canvas, continuous-ish corner radius.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let radius: CGFloat = 186
let path = CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor.black.withAlphaComponent(0.35).cgColor)
ctx.addPath(path)
ctx.setFillColor(NSColor(srgbRed: 0.10, green: 0.10, blue: 0.12, alpha: 1).cgColor)
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(path)
ctx.clip()
let gradient = CGGradient(
    colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
    colors: [
        NSColor(srgbRed: 0.20, green: 0.20, blue: 0.24, alpha: 1).cgColor,
        NSColor(srgbRed: 0.09, green: 0.09, blue: 0.11, alpha: 1).cgColor,
    ] as CFArray,
    locations: [0, 1])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.minY), options: [])

// Faint pane divider, a nod to side-by-side sessions.
ctx.setFillColor(NSColor.white.withAlphaComponent(0.06).cgColor)
ctx.fill(CGRect(x: body.midX + 120, y: body.minY, width: 6, height: body.height))
ctx.restoreGState()

// Inner hairline.
ctx.addPath(CGPath(roundedRect: body.insetBy(dx: 2, dy: 2), cornerWidth: radius - 2, cornerHeight: radius - 2, transform: nil))
ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.10).cgColor)
ctx.setLineWidth(4)
ctx.strokePath()

// Prompt glyph: chevron and cursor in Claude orange.
let orange = NSColor(srgbRed: 0.851, green: 0.467, blue: 0.341, alpha: 1)
ctx.setStrokeColor(orange.cgColor)
ctx.setLineWidth(64)
ctx.setLineCap(.round)
ctx.setLineJoin(.round)
ctx.move(to: CGPoint(x: 268, y: 640))
ctx.addLine(to: CGPoint(x: 428, y: 512))
ctx.addLine(to: CGPoint(x: 268, y: 384))
ctx.strokePath()

ctx.setFillColor(orange.withAlphaComponent(0.9).cgColor)
ctx.fill(CGRect(x: 476, y: 352, width: 170, height: 60))

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    fputs("failed to render icon\n", stderr)
    exit(1)
}
try png.write(to: URL(fileURLWithPath: out))
