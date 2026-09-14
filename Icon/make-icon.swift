// CornerCal app icon: a screen's bottom-right corner, and nothing else (his brief, 14 Sep 2026).
// Build: swiftc -sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk -target arm64-apple-macos14.0 make-icon.swift -o mkicon
// Run:   ./mkicon <outdir>   -> <outdir>/AppIcon.iconset/*.png + icon-1024.png (then iconutil -c icns)
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let iconset = out.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func render(_ px: Int) -> NSBitmapImageRep {
  let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                             hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
  rep.size = NSSize(width: px, height: px)
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
  let ctx = NSGraphicsContext.current!.cgContext
  ctx.scaleBy(x: CGFloat(px) / 1024, y: CGFloat(px) / 1024)

  // Apple icon grid: 824 body centred on 1024, soft shadow.
  let body = CGRect(x: 100, y: 100, width: 824, height: 824)
  let tile = CGPath(roundedRect: body, cornerWidth: 186, cornerHeight: 186, transform: nil)
  ctx.saveGState()
  ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor(white: 0, alpha: 0.28).cgColor)
  ctx.addPath(tile); ctx.setFillColor(NSColor.black.cgColor); ctx.fillPath()
  ctx.restoreGState()

  let space = CGColorSpace(name: CGColorSpace.sRGB)!
  ctx.saveGState()
  ctx.addPath(tile); ctx.clip()
  let bg = CGGradient(colorsSpace: space, colors: [NSColor(srgbRed: 0.23, green: 0.25, blue: 0.31, alpha: 1).cgColor,
                                                   NSColor(srgbRed: 0.08, green: 0.09, blue: 0.12, alpha: 1).cgColor] as CFArray,
                      locations: [0, 1])!
  ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: 924), end: CGPoint(x: 0, y: 100), options: [])

  // The corner: a thick rounded L hugging the bottom-right, like the edge of a screen.
  let w: CGFloat = px <= 32 ? 100 : 76
  let inset: CGFloat = 200
  let right = body.maxX - inset, bottom = body.minY + inset
  let len: CGFloat = 340, r: CGFloat = 130
  let path = CGMutablePath()
  path.move(to: CGPoint(x: right, y: bottom + len))
  path.addLine(to: CGPoint(x: right, y: bottom + r))
  path.addArc(tangent1End: CGPoint(x: right, y: bottom), tangent2End: CGPoint(x: right - r, y: bottom), radius: r)
  path.addLine(to: CGPoint(x: right - len, y: bottom))
  ctx.addPath(path)
  ctx.setLineWidth(w); ctx.setLineCap(.round); ctx.setLineJoin(.round)
  ctx.replacePathWithStrokedPath()
  ctx.clip()
  let ink = CGGradient(colorsSpace: space, colors: [NSColor(srgbRed: 0.47, green: 0.87, blue: 0.64, alpha: 1).cgColor,
                                                    NSColor(srgbRed: 0.20, green: 0.71, blue: 0.47, alpha: 1).cgColor] as CFArray,
                       locations: [0, 1])!
  ctx.drawLinearGradient(ink, start: CGPoint(x: 0, y: bottom + len + w), end: CGPoint(x: 0, y: bottom - w), options: [])
  ctx.restoreGState()

  // Hairline rim so the tile keeps its edge on dark backgrounds.
  ctx.addPath(CGPath(roundedRect: body.insetBy(dx: 1.5, dy: 1.5), cornerWidth: 185, cornerHeight: 185, transform: nil))
  ctx.setStrokeColor(NSColor(white: 1, alpha: 0.10).cgColor); ctx.setLineWidth(3); ctx.strokePath()

  NSGraphicsContext.restoreGraphicsState()
  return rep
}

func save(_ rep: NSBitmapImageRep, _ url: URL) { try! rep.representation(using: .png, properties: [:])!.write(to: url) }

for (pt, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
  save(render(pt * scale), iconset.appendingPathComponent("icon_\(pt)x\(pt)\(scale == 2 ? "@2x" : "").png"))
}
save(render(1024), out.appendingPathComponent("icon-1024.png"))
