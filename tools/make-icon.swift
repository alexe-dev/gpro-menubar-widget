import AppKit

// A chart line climbing out of a dark squircle: readable at 16pt, not a logo pastiche.
// Rendered into an explicit pixel buffer: locking focus on an NSImage would pick up the
// screen's backing scale and silently double every size.
func drawIcon(size: CGFloat) -> NSBitmapImageRep? {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                     pixelsWide: Int(size), pixelsHigh: Int(size),
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                     isPlanar: false, colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0),
          let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    let ctx = context.cgContext

    let inset = size * 0.085                      // macOS icons sit inside their canvas
    let rect = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let radius = rect.width * 0.2237              // Apple's continuous-corner proportion
    let squircle = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

    ctx.saveGState()
    squircle.addClip()
    let colors = [
        NSColor(srgbRed: 0.13, green: 0.15, blue: 0.19, alpha: 1).cgColor,
        NSColor(srgbRed: 0.05, green: 0.06, blue: 0.08, alpha: 1).cgColor,
    ]
    if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                 colors: colors as CFArray, locations: [0, 1]) {
        ctx.drawLinearGradient(gradient,
                               start: CGPoint(x: rect.minX, y: rect.maxY),
                               end: CGPoint(x: rect.maxX, y: rect.minY),
                               options: [])
    }

    // The line: three steps up in the accent green. No area fill — at 16pt it collapses
    // into a smudge and its vertical edges read as artefacts.
    let points = [
        CGPoint(x: 0.22, y: 0.34), CGPoint(x: 0.40, y: 0.52),
        CGPoint(x: 0.53, y: 0.43), CGPoint(x: 0.74, y: 0.71),
    ].map { CGPoint(x: rect.minX + rect.width * $0.x, y: rect.minY + rect.height * $0.y) }

    let line = CGMutablePath()
    line.move(to: points[0])
    points.dropFirst().forEach { line.addLine(to: $0) }
    ctx.setStrokeColor(NSColor(srgbRed: 0.26, green: 0.84, blue: 0.50, alpha: 1).cgColor)
    ctx.setLineWidth(size * 0.058)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.addPath(line)
    ctx.strokePath()

    // A dot at the last point, the way a live quote marks itself.
    let dot = size * 0.052
    ctx.setFillColor(NSColor.white.cgColor)
    ctx.fillEllipse(in: CGRect(x: points.last!.x - dot, y: points.last!.y - dot,
                               width: dot * 2, height: dot * 2))
    ctx.restoreGState()

    // A hairline edge keeps the shape crisp on light wallpapers.
    NSColor(white: 1, alpha: 0.10).setStroke()
    squircle.lineWidth = max(1, size * 0.004)
    squircle.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let iconset = URL(fileURLWithPath: "icon.iconset")
try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

for (size, name) in [(16, "16x16"), (32, "16x16@2x"), (32, "32x32"), (64, "32x32@2x"),
                     (128, "128x128"), (256, "128x128@2x"), (256, "256x256"), (512, "256x256@2x"),
                     (512, "512x512"), (1024, "512x512@2x")] {
    guard let bitmap = drawIcon(size: CGFloat(size)),
          let png = bitmap.representation(using: .png, properties: [:]) else { continue }
    try? png.write(to: iconset.appendingPathComponent("icon_\(name).png"))
}
print("icon.iconset ready")
