import AppKit

let S: CGFloat = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(S), pixelsHigh: Int(S), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext
// Flip to top-left origin for easier coordinates.
ctx.translateBy(x: 0, y: S); ctx.scaleBy(x: 1, y: -1)

func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}
let space = CGColorSpace(name: CGColorSpace.sRGB)!

// macOS icon grid: 824×824 body centered, ~185pt continuous corners.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let bodyPath = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)

// Drop shadow of the whole tile.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: 18), blur: 40, color: color(0x000000, 0.35))
ctx.addPath(bodyPath); ctx.setFillColor(color(0x1B1D2B)); ctx.fillPath()
ctx.restoreGState()

// Background glows, clipped to the tile.
ctx.saveGState()
ctx.addPath(bodyPath); ctx.clip()
let base = CGGradient(colorsSpace: space, colors: [color(0x23263A), color(0x12131D)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(base, start: CGPoint(x: 100, y: 100), end: CGPoint(x: 924, y: 924), options: [])
func glow(_ c: UInt32, _ center: CGPoint, _ r: CGFloat, _ a: CGFloat) {
    let g = CGGradient(colorsSpace: space, colors: [color(c, a), color(c, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(g, startCenter: center, startRadius: 0, endCenter: center, endRadius: r, options: [])
}
glow(0xFF7A45, CGPoint(x: 290, y: 760), 520, 0.95)
glow(0x7B61FF, CGPoint(x: 760, y: 330), 540, 0.95)
glow(0xFF4FA3, CGPoint(x: 620, y: 860), 300, 0.45)

// Frosted glass panel.
let glass = body.insetBy(dx: 70, dy: 70)
let glassPath = CGPath(roundedRect: glass, cornerWidth: 130, cornerHeight: 130, transform: nil)
ctx.saveGState()
ctx.addPath(glassPath); ctx.clip()
let frost = CGGradient(colorsSpace: space, colors: [color(0xFFFFFF, 0.26), color(0xFFFFFF, 0.08)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(frost, start: CGPoint(x: glass.minX, y: glass.minY), end: CGPoint(x: glass.maxX, y: glass.maxY), options: [])
// Specular sheen along the top edge.
let sheen = CGGradient(colorsSpace: space, colors: [color(0xFFFFFF, 0.28), color(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(sheen, start: CGPoint(x: 0, y: glass.minY), end: CGPoint(x: 0, y: glass.minY + 160), options: [])
ctx.restoreGState()
ctx.addPath(glassPath); ctx.setStrokeColor(color(0xFFFFFF, 0.5)); ctx.setLineWidth(4); ctx.strokePath()

// The notch, hanging from the top of the glass.
let notch = CGMutablePath()
let nx0: CGFloat = 330, nx1: CGFloat = 694, ny0 = glass.minY, ny1 = glass.minY + 96, r: CGFloat = 44
notch.move(to: CGPoint(x: nx0 - 26, y: ny0))
notch.addQuadCurve(to: CGPoint(x: nx0, y: ny0 + 26), control: CGPoint(x: nx0, y: ny0))
notch.addLine(to: CGPoint(x: nx0, y: ny1 - r))
notch.addQuadCurve(to: CGPoint(x: nx0 + r, y: ny1), control: CGPoint(x: nx0, y: ny1))
notch.addLine(to: CGPoint(x: nx1 - r, y: ny1))
notch.addQuadCurve(to: CGPoint(x: nx1, y: ny1 - r), control: CGPoint(x: nx1, y: ny1))
notch.addLine(to: CGPoint(x: nx1, y: ny0 + 26))
notch.addQuadCurve(to: CGPoint(x: nx1 + 26, y: ny0), control: CGPoint(x: nx1, y: ny0))
notch.closeSubpath()
ctx.saveGState(); ctx.addPath(glassPath); ctx.clip()
ctx.addPath(notch); ctx.setFillColor(color(0x07080D)); ctx.fillPath()
ctx.restoreGState()

// The bird, perched on the notch.
func birdPath() -> CGPath {
    let p = CGMutablePath()
    // Body: rounded teardrop, belly down, tail to the left.
    p.move(to: CGPoint(x: 600, y: 300))                        // back of the head
    p.addCurve(to: CGPoint(x: 668, y: 380), control1: CGPoint(x: 640, y: 296), control2: CGPoint(x: 668, y: 330))   // forehead → chest
    p.addCurve(to: CGPoint(x: 560, y: 560), control1: CGPoint(x: 668, y: 470), control2: CGPoint(x: 640, y: 548))   // chest → belly
    p.addCurve(to: CGPoint(x: 420, y: 520), control1: CGPoint(x: 500, y: 568), control2: CGPoint(x: 452, y: 548))   // belly → under tail
    p.addLine(to: CGPoint(x: 300, y: 590))                    // tail tip low
    p.addLine(to: CGPoint(x: 336, y: 470))                    // tail top
    p.addCurve(to: CGPoint(x: 520, y: 360), control1: CGPoint(x: 390, y: 420), control2: CGPoint(x: 460, y: 380))   // back
    p.addCurve(to: CGPoint(x: 600, y: 300), control1: CGPoint(x: 552, y: 350), control2: CGPoint(x: 566, y: 304))   // nape
    p.closeSubpath()
    return p
}
let bird = birdPath()
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: 14), blur: 30, color: color(0x000000, 0.35))
ctx.addPath(bird); ctx.setFillColor(color(0xFFFFFF)); ctx.fillPath()
ctx.restoreGState()
// Soft shading on the bird.
ctx.saveGState(); ctx.addPath(bird); ctx.clip()
let shade = CGGradient(colorsSpace: space, colors: [color(0xFFFFFF, 0), color(0xC9C3FF, 0.55)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(shade, start: CGPoint(x: 560, y: 320), end: CGPoint(x: 420, y: 580), options: [])
// Wing.
let wing = CGMutablePath()
wing.move(to: CGPoint(x: 600, y: 420))
wing.addCurve(to: CGPoint(x: 380, y: 500), control1: CGPoint(x: 560, y: 500), control2: CGPoint(x: 460, y: 520))
wing.addCurve(to: CGPoint(x: 600, y: 420), control1: CGPoint(x: 450, y: 440), control2: CGPoint(x: 540, y: 410))
ctx.addPath(wing); ctx.setFillColor(color(0xD8D3FF, 0.9)); ctx.fillPath()
ctx.restoreGState()
// Beak.
let beak = CGMutablePath()
beak.move(to: CGPoint(x: 662, y: 352)); beak.addLine(to: CGPoint(x: 724, y: 366)); beak.addLine(to: CGPoint(x: 664, y: 392)); beak.closeSubpath()
ctx.addPath(beak); ctx.setFillColor(color(0xFFC857)); ctx.fillPath()
// Eye.
ctx.setFillColor(color(0x1B1D2B)); ctx.fillEllipse(in: CGRect(x: 612, y: 336, width: 26, height: 26))
ctx.setFillColor(color(0xFFFFFF)); ctx.fillEllipse(in: CGRect(x: 622, y: 340, width: 8, height: 8))
// Feet gripping the notch edge.
ctx.setStrokeColor(color(0xFFC857)); ctx.setLineWidth(12); ctx.setLineCap(.round)
for x in [500.0, 548.0] { ctx.move(to: CGPoint(x: x, y: 556)); ctx.addLine(to: CGPoint(x: x - 6, y: 600)); ctx.strokePath() }

// A few equalizer bars on the glass below.
let bars: [CGFloat] = [70, 120, 170, 120, 200, 140, 90, 150, 60]
let bw: CGFloat = 34, gap: CGFloat = 18
let total = CGFloat(bars.count) * bw + CGFloat(bars.count - 1) * gap
var x = (S - total) / 2
for h in bars {
    let rect = CGRect(x: x, y: 790 - h, width: bw, height: h)
    let path = CGPath(roundedRect: rect, cornerWidth: bw / 2, cornerHeight: bw / 2, transform: nil)
    ctx.saveGState(); ctx.addPath(path); ctx.clip()
    let g = CGGradient(colorsSpace: space, colors: [color(0xFFFFFF, 0.95), color(0xFFFFFF, 0.35)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: rect.minY), end: CGPoint(x: 0, y: rect.maxY), options: [])
    ctx.restoreGState()
    x += bw + gap
}

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
