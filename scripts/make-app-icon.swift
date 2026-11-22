// Draws the app icon (1024×1024 PNG) from plain shapes: a watchtower on a dark teal tile. Our own art, so the icon no
// longer uses game artwork (it used to be the 维多利亚 covenant emblem). No SF Symbols either: Apple's licence doesn't
// allow them in app icons.
// Usage: swift scripts/make-app-icon.swift Resources/AppIcon.png
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources/AppIcon.png"
let size = 1024
let space = CGColorSpaceCreateDeviceRGB()
guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { fatalError("no context") }
func color(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor { CGColor(red: r, green: g, blue: b, alpha: a) }
func rect(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double) -> CGRect { CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0) }

// Tile: macOS icon grid (824 pt body in a 1024 canvas), rounded, dark navy → teal.
let tile = rect(100, 100, 924, 924)
let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0, 0, 0, 0.35))
ctx.addPath(tilePath); ctx.setFillColor(color(0.05, 0.10, 0.16)); ctx.fillPath()
ctx.restoreGState()
ctx.saveGState()
ctx.addPath(tilePath); ctx.clip()
let gradient = CGGradient(colorsSpace: space, colors: [color(0.04, 0.09, 0.15), color(0.03, 0.30, 0.36)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
// Faint grid, like the board.
ctx.setStrokeColor(color(1, 1, 1, 0.05)); ctx.setLineWidth(4)
for k in stride(from: 100.0, through: 924.0, by: 103.0) {
    ctx.move(to: CGPoint(x: k, y: 100)); ctx.addLine(to: CGPoint(x: k, y: 924))
    ctx.move(to: CGPoint(x: 100, y: k)); ctx.addLine(to: CGPoint(x: 924, y: k))
}
ctx.strokePath()
ctx.restoreGState()

// Watchtower.
let white = color(0.96, 0.98, 0.99)
ctx.setFillColor(white)
func rounded(_ r: CGRect, _ radius: Double) { ctx.addPath(CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)); ctx.fillPath() }
rounded(rect(322, 250, 702, 318), 22)                       // base
let body = CGMutablePath()                                    // tapered body
body.move(to: CGPoint(x: 362, y: 318)); body.addLine(to: CGPoint(x: 662, y: 318))
body.addLine(to: CGPoint(x: 632, y: 628)); body.addLine(to: CGPoint(x: 392, y: 628)); body.closeSubpath()
ctx.addPath(body); ctx.fillPath()
rounded(rect(352, 620, 672, 688), 14)                       // platform
for x in [352.0, 467.0, 582.0] { rounded(rect(x, 680, x + 90, 774), 12) }   // battlements
// Arrow slit (cut out with the tile colour).
ctx.setFillColor(color(0.04, 0.17, 0.23))
rounded(rect(492, 430, 532, 548), 20)
// Cyan accent under the tower (the game's UI colour).
ctx.setFillColor(color(0.20, 0.85, 0.95))
rounded(rect(322, 196, 702, 220), 12)

guard let image = ctx.makeImage(), let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
    fatalError("no image")
}
try! png.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
