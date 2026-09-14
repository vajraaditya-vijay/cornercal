// make-icon.swift
// Draws the CornerCal app icon with CoreGraphics into a full macOS .iconset,
// compiles it to AppIcon.icns, and writes icon-1024.png + contact-sheet.png.
//
// Idea: "the corner". A deep glass tile reads as a screen corner; a chunky
// liquid-glass capsule (the live event pill, ~60% filled) nestles into the
// bottom-right curve, a frosted day timeline springs up behind it, and the
// pointer rests in the corner. Shipped colourway: "night-green" (the default).
//
// Build (the default 27.0 SDK is broken with swiftc 6.3.3):
//   swiftc -sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk \
//     -target arm64-apple-macos14.0 make-icon.swift -o /tmp/claude-504/mkicon
//   /tmp/claude-504/mkicon <outdir> [variant]

import CoreGraphics
import Foundation
import ImageIO

func hex(_ v: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255,
            blue: CGFloat(v & 0xff) / 255, alpha: a)
}
func white(_ a: CGFloat) -> CGColor { CGColor(red: 1, green: 1, blue: 1, alpha: a) }
func black(_ a: CGFloat) -> CGColor { CGColor(red: 0, green: 0, blue: 0, alpha: a) }
let space = CGColorSpaceCreateDeviceRGB()
func grad(_ colors: [CGColor], _ locs: [CGFloat]) -> CGGradient {
    CGGradient(colorsSpace: space, colors: colors as CFArray, locations: locs)!
}

struct Variant {
    var bgTop: UInt32, bgBottom: UInt32, glow: UInt32
    var fillTop: UInt32, fill: UInt32, fillDeep: UInt32
    var panel: Bool = true
    var cursor: Bool = true
}
let variants: [String: Variant] = [
    "indigo": Variant(bgTop: 0x6b4fd8, bgBottom: 0x2b2e8f, glow: 0xa592ff,
                      fillTop: 0x7be8b0, fill: 0x33b679, fillDeep: 0x218c5c),
    "indigo-bare": Variant(bgTop: 0x6b4fd8, bgBottom: 0x2b2e8f, glow: 0xa592ff,
                           fillTop: 0x7be8b0, fill: 0x33b679, fillDeep: 0x218c5c, panel: false),
    "night": Variant(bgTop: 0x3b3f9e, bgBottom: 0x121433, glow: 0x7986cb,
                     fillTop: 0x6ad2ff, fill: 0x039be5, fillDeep: 0x0277bd),
    "night-green": Variant(bgTop: 0x4347b0, bgBottom: 0x14163a, glow: 0x8a95e0,
                           fillTop: 0x7be8b0, fill: 0x33b679, fillDeep: 0x218c5c),
    "night-green-nocursor": Variant(bgTop: 0x4347b0, bgBottom: 0x14163a, glow: 0x8a95e0,
                           fillTop: 0x7be8b0, fill: 0x33b679, fillDeep: 0x218c5c, cursor: false),
    "teal": Variant(bgTop: 0x1a9a9a, bgBottom: 0x0d2236, glow: 0x5fe0d0,
                    fillTop: 0xffe27f, fill: 0xf6bf26, fillDeep: 0xd99a0b),
]

// MARK: - Shapes

/// Apple-style continuous-corner rounded rect (the iOS 7 bezier approximation):
/// each corner eases in over 1.53 r, so curvature has no jump at the straight edge.
func squircle(_ rect: CGRect, radius r: CGFloat) -> CGPath {
    let p = CGMutablePath()
    // (corner, u = incoming edge direction, w = outgoing edge direction), CCW in y-up space.
    let corners: [(CGPoint, CGVector, CGVector)] = [
        (CGPoint(x: rect.maxX, y: rect.minY), CGVector(dx: 1, dy: 0), CGVector(dx: 0, dy: 1)),
        (CGPoint(x: rect.maxX, y: rect.maxY), CGVector(dx: 0, dy: 1), CGVector(dx: -1, dy: 0)),
        (CGPoint(x: rect.minX, y: rect.maxY), CGVector(dx: -1, dy: 0), CGVector(dx: 0, dy: -1)),
        (CGPoint(x: rect.minX, y: rect.minY), CGVector(dx: 0, dy: -1), CGVector(dx: 1, dy: 0)),
    ]
    for (i, (c, u, w)) in corners.enumerated() {
        func q(_ a: CGFloat, _ b: CGFloat) -> CGPoint {
            CGPoint(x: c.x - a * r * u.dx + b * r * w.dx, y: c.y - a * r * u.dy + b * r * w.dy)
        }
        if i == 0 { p.move(to: q(1.52866483, 0)) } else { p.addLine(to: q(1.52866483, 0)) }
        p.addCurve(to: q(0.63149399, 0.07491100), control1: q(1.08849323, 0), control2: q(0.86840689, 0.02440034))
        p.addCurve(to: q(0.07491100, 0.63149399), control1: q(0.37282392, 0.16840687), control2: q(0.16840687, 0.37282392))
        p.addCurve(to: q(0, 1.52866483), control1: q(0.02440034, 0.86840689), control2: q(0, 1.08849323))
    }
    p.closeSubpath()
    return p
}

func capsule(_ r: CGRect) -> CGPath {
    CGPath(roundedRect: r, cornerWidth: r.height / 2, cornerHeight: r.height / 2, transform: nil)
}

/// Stroke-clip a path and paint a vertical gradient into it (rim lights).
func rim(_ ctx: CGContext, _ path: CGPath, width: CGFloat, top: CGFloat, bottom: CGFloat,
         _ colors: [CGColor], _ locs: [CGFloat]) {
    ctx.saveGState()
    ctx.addPath(path); ctx.setLineWidth(width)
    ctx.replacePathWithStrokedPath(); ctx.clip()
    ctx.drawLinearGradient(grad(colors, locs), start: CGPoint(x: 0, y: top), end: CGPoint(x: 0, y: bottom), options: [])
    ctx.restoreGState()
}

/// Inner shadow along the top edge of `path`.
func innerShadow(_ ctx: CGContext, _ path: CGPath, bounds: CGRect, dy: CGFloat, blur: CGFloat, alpha: CGFloat, sc: CGFloat) {
    ctx.saveGState()
    ctx.addPath(path); ctx.clip()
    let ring = CGMutablePath()
    ring.addRect(bounds.insetBy(dx: -300, dy: -300))
    ring.addPath(path)
    ctx.setShadow(offset: CGSize(width: 0, height: dy * sc), blur: blur * sc, color: black(alpha))
    ctx.addPath(ring); ctx.setFillColor(black(1)); ctx.fillPath(using: .evenOdd)
    ctx.restoreGState()
}

// MARK: - Drawing

func drawIcon(ctx: CGContext, size: CGFloat, v: Variant) {
    let canvas: CGFloat = 1024
    ctx.saveGState()
    ctx.scaleBy(x: size / canvas, y: size / canvas)
    let sc = size / canvas
    let small = size < 60     // 16/32px: drop the panel, thicken rims
    let tiny = size < 24

    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = squircle(tile, radius: 175)

    // Baked shadow.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * sc), blur: 30 * sc, color: black(0.35))
    ctx.addPath(tilePath); ctx.setFillColor(hex(v.bgBottom)); ctx.fillPath()
    ctx.restoreGState()

    // Background.
    ctx.saveGState()
    ctx.addPath(tilePath); ctx.clip()
    ctx.drawLinearGradient(grad([hex(v.bgTop), hex(v.bgBottom)], [0, 1]),
                           start: CGPoint(x: 220, y: 924), end: CGPoint(x: 820, y: 100), options: [])
    ctx.drawRadialGradient(grad([hex(v.glow, 0.50), hex(v.glow, 0)], [0, 1]),
                           startCenter: CGPoint(x: 230, y: 900), startRadius: 0,
                           endCenter: CGPoint(x: 230, y: 900), endRadius: 600, options: [])
    // Colour spill from the pill onto the "desk".
    ctx.drawRadialGradient(grad([hex(v.fill, 0.35), hex(v.fill, 0)], [0, 1]),
                           startCenter: CGPoint(x: 460, y: 200), startRadius: 0,
                           endCenter: CGPoint(x: 460, y: 200), endRadius: 380, options: [])

    // Pill: tucked into the bottom-right corner, roughly concentric with the tile curve.
    // At 16/32px the pill grows so its silhouette survives.
    let pill = small ? CGRect(x: 190, y: 150, width: 684, height: 300) : CGRect(x: 318, y: 150, width: 556, height: 216)
    let pillPath = capsule(pill)

    // Frosted day-timeline panel springing up out of the corner, behind the pill.
    if v.panel && !small {
        let panel = CGRect(x: 462, y: 250, width: 412, height: 596)
        let panelPath = CGPath(roundedRect: panel, cornerWidth: 70, cornerHeight: 70, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -14 * sc), blur: 40 * sc, color: black(0.28))
        ctx.addPath(panelPath); ctx.setFillColor(white(0.13)); ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(panelPath); ctx.clip()
        ctx.drawLinearGradient(grad([white(0.14), white(0.02)], [0, 1]),
                               start: CGPoint(x: 0, y: panel.maxY), end: CGPoint(x: 0, y: panel.minY), options: [])
        // Hour lines.
        for i in 0..<5 {
            let y = panel.maxY - 70 - CGFloat(i) * 100
            ctx.setFillColor(white(0.16))
            ctx.fill(CGRect(x: panel.minX + 40, y: y, width: panel.width - 40, height: 4))
        }
        // Event blocks (Google Calendar muted colours).
        let blocks: [(CGRect, UInt32)] = [
            (CGRect(x: panel.minX + 50, y: panel.maxY - 236, width: 290, height: 136), 0x7986cb),
            (CGRect(x: panel.minX + 50, y: panel.maxY - 348, width: 210, height: 84), 0xe67c73),
        ]
        for (r, c) in blocks {
            let bp = CGPath(roundedRect: r, cornerWidth: 26, cornerHeight: 26, transform: nil)
            ctx.addPath(bp); ctx.setFillColor(hex(c, 0.88)); ctx.fillPath()
            ctx.saveGState(); ctx.addPath(bp); ctx.clip()
            ctx.drawLinearGradient(grad([white(0.22), white(0)], [0, 1]),
                                   start: CGPoint(x: 0, y: r.maxY), end: CGPoint(x: 0, y: r.midY), options: [])
            ctx.restoreGState()
        }
        ctx.restoreGState()
        rim(ctx, panelPath, width: 5, top: panel.maxY, bottom: panel.minY,
            [white(0.55), white(0.08)], [0, 0.6])
    }

    // Tile glass edge.
    rim(ctx, tilePath, width: small ? 16 : 8, top: 924, bottom: 100,
        [white(0.40), white(0.04), white(0.10)], [0, 0.5, 1])

    // --- Pill ---
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -20 * sc), blur: 44 * sc, color: black(0.42))
    ctx.addPath(pillPath); ctx.setFillColor(hex(v.bgBottom)); ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(pillPath); ctx.clip()
    // Frosted glass remainder: milky, tinted by the background.
    ctx.drawLinearGradient(grad([hex(v.glow, 0.62), hex(v.bgBottom, 0.55)], [0, 1]),
                           start: CGPoint(x: 0, y: pill.maxY), end: CGPoint(x: 0, y: pill.minY), options: [])
    ctx.setFillColor(white(0.10)); ctx.fill(pill)
    // Progress fill, left 60%, with a soft glowing leading edge (no hard divider).
    let fillX = pill.minX + pill.width * 0.60
    ctx.saveGState()
    ctx.clip(to: CGRect(x: pill.minX, y: pill.minY, width: fillX - pill.minX, height: pill.height))
    ctx.drawLinearGradient(grad([hex(v.fillTop), hex(v.fill), hex(v.fillDeep)], [0, 0.45, 1]),
                           start: CGPoint(x: 0, y: pill.maxY), end: CGPoint(x: 0, y: pill.minY), options: [])
    ctx.drawLinearGradient(grad([white(0), white(tiny ? 0 : 0.28)], [0, 1]),
                           start: CGPoint(x: fillX - 46, y: 0), end: CGPoint(x: fillX, y: 0), options: [])
    ctx.restoreGState()
    // Light the frosted side just past the edge.
    if !tiny {
        ctx.drawLinearGradient(grad([hex(v.fill, 0.30), hex(v.fill, 0)], [0, 1]),
                               start: CGPoint(x: fillX, y: 0), end: CGPoint(x: fillX + 40, y: 0), options: [])
    }
    // Inner top glow (light entering the glass).
    ctx.drawLinearGradient(grad([white(0.30), white(0)], [0, 1]),
                           start: CGPoint(x: 0, y: pill.maxY), end: CGPoint(x: 0, y: pill.maxY - 70), options: [])
    ctx.restoreGState()
    innerShadow(ctx, pillPath, bounds: pill, dy: 8, blur: 22, alpha: 0.30, sc: sc) // bottom-edge depth
    innerShadow(ctx, pillPath, bounds: pill, dy: -6, blur: 14, alpha: 0.18, sc: sc)

    // Specular rim: hot along the top, a faint bounce along the bottom.
    rim(ctx, capsule(pill.insetBy(dx: 2.5, dy: 2.5)), width: small ? 14 : 6, top: pill.maxY, bottom: pill.minY,
        [white(0.95), white(0.10), white(0.05), white(0.40)], [0, 0.45, 0.7, 1])

    // The pointer, resting in the corner.
    if v.cursor && !small {
        let arrow: [(CGFloat, CGFloat)] = [(0, 0), (0, 17), (4, 13.2), (7, 19.5), (9.4, 18.5), (6.5, 12.3), (12, 12.3)]
        let k: CGFloat = 7.0
        let tip = CGPoint(x: 748, y: 322)
        let ap = CGMutablePath()
        for (i, pt) in arrow.enumerated() {
            let q = CGPoint(x: tip.x + pt.0 * k, y: tip.y - pt.1 * k)
            if i == 0 { ap.move(to: q) } else { ap.addLine(to: q) }
        }
        ap.closeSubpath()
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -8 * sc), blur: 18 * sc, color: black(0.45))
        ctx.addPath(ap); ctx.setFillColor(hex(0x111111)); ctx.fillPath()
        ctx.restoreGState()
        ctx.addPath(ap); ctx.setLineWidth(11); ctx.setLineJoin(.round)
        ctx.setStrokeColor(hex(0x111111)); ctx.strokePath()
        ctx.addPath(ap); ctx.setFillColor(white(1)); ctx.fillPath()
    }

    ctx.restoreGState() // tile clip
    ctx.restoreGState() // scale
}

// MARK: - Output

func render(_ px: Int, _ v: Variant) -> CGImage {
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    drawIcon(ctx: ctx, size: CGFloat(px), v: v)
    return ctx.makeImage()!
}

func writePNG(_ img: CGImage, _ url: URL) {
    let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, img, nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("PNG write failed: \(url.path)") }
}

/// 1024 on the left; 64/32/16 at 4x (nearest-neighbour) plus 1x, on light and dark strips.
func contactSheet(_ v: Variant) -> CGImage {
    let W = 1900, H = 1100
    let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(hex(0xececf0)); ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
    ctx.setFillColor(hex(0x1e1e22)); ctx.fill(CGRect(x: 1560, y: 0, width: 340, height: H))
    ctx.draw(render(1024, v), in: CGRect(x: 30, y: 38, width: 1024, height: 1024))
    var y = 1062
    for s in [64, 32, 16] {
        let img = render(s, v)
        let big = s * 4
        y -= big + 40
        ctx.interpolationQuality = .none
        ctx.draw(img, in: CGRect(x: 1110, y: y, width: big, height: big))
        ctx.draw(img, in: CGRect(x: 1110 + big + 30, y: y, width: s, height: s))
        ctx.draw(img, in: CGRect(x: 1600, y: y, width: s, height: s))
        ctx.draw(img, in: CGRect(x: 1600 + s + 20, y: y, width: s * 2, height: s * 2))
    }
    return ctx.makeImage()!
}

let args = CommandLine.arguments
guard args.count >= 2 else { print("Usage: mkicon <outdir> [indigo|indigo-bare|night|night-green|night-green-nocursor|teal]"); exit(1) }
let name = args.count >= 3 ? args[2] : "night-green"
guard let v = variants[name] else { print("unknown variant \(name)"); exit(1) }
let outDir = URL(fileURLWithPath: args[1], isDirectory: true)
let iconset = outDir.appendingPathComponent("AppIcon.iconset", isDirectory: true)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

let entries: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32), ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64), ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512), ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]
for (file, s) in entries { writePNG(render(s, v), iconset.appendingPathComponent(file)) }
writePNG(render(1024, v), outDir.appendingPathComponent("icon-1024.png"))
for s in [64, 32, 16] { writePNG(render(s, v), outDir.appendingPathComponent("icon-\(s).png")) }
writePNG(contactSheet(v), outDir.appendingPathComponent("contact-sheet.png"))

let proc = Process()
proc.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
proc.arguments = ["-c", "icns", iconset.path, "-o", outDir.appendingPathComponent("AppIcon.icns").path]
try proc.run(); proc.waitUntilExit()
print("variant \(name) -> \(outDir.path) (iconutil status \(proc.terminationStatus))")
