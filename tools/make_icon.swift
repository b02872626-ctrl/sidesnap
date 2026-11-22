// Draws the Sidesnap app icon (two stacked screenshots on a dark tile) and
// writes Resources/Sidesnap.icns. Run with: tools/make_icon.sh
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: r / 255, green: g / 255, blue: b / 255, alpha: a)
}

// Tile on Apple's icon grid: 824 px inside a 1024 canvas.
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: rgb(0, 0, 0, 0.35))
ctx.addPath(tilePath)
ctx.setFillColor(rgb(36, 36, 40))
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(tilePath)
ctx.clip()
let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                      colors: [rgb(58, 58, 64), rgb(26, 26, 30)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(grad, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
// Faint top edge, like light catching glass.
ctx.setStrokeColor(rgb(255, 255, 255, 0.10))
ctx.setLineWidth(4)
ctx.addPath(CGPath(roundedRect: tile.insetBy(dx: 2, dy: 2), cornerWidth: 183, cornerHeight: 183, transform: nil))
ctx.strokePath()

func card(_ r: CGRect, fill: CGColor, shadow: CGFloat) {
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: shadow, color: rgb(0, 0, 0, 0.45))
    ctx.addPath(CGPath(roundedRect: r, cornerWidth: 46, cornerHeight: 46, transform: nil))
    ctx.setFillColor(fill)
    ctx.fillPath()
    ctx.restoreGState()
}

// Back screenshot, up and to the right.
card(CGRect(x: 318, y: 420, width: 470, height: 320), fill: rgb(110, 110, 118), shadow: 18)
// Front screenshot.
let front = CGRect(x: 236, y: 300, width: 500, height: 340)
card(front, fill: rgb(242, 242, 247), shadow: 30)

// A calm picture on the front card: sky band and two hills.
ctx.saveGState()
ctx.addPath(CGPath(roundedRect: front.insetBy(dx: 26, dy: 26), cornerWidth: 26, cornerHeight: 26, transform: nil))
ctx.clip()
let inner = front.insetBy(dx: 26, dy: 26)
ctx.setFillColor(rgb(206, 220, 236)); ctx.fill(inner)
ctx.setFillColor(rgb(120, 148, 176))
ctx.fillEllipse(in: CGRect(x: inner.minX - 60, y: inner.minY - 170, width: 330, height: 300))
ctx.setFillColor(rgb(86, 112, 140))
ctx.fillEllipse(in: CGRect(x: inner.minX + 150, y: inner.minY - 210, width: 420, height: 330))
ctx.setFillColor(rgb(255, 255, 255, 0.9))
ctx.fillEllipse(in: CGRect(x: inner.maxX - 120, y: inner.maxY - 110, width: 62, height: 62))
ctx.restoreGState()
ctx.restoreGState()

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
