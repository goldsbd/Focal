// Renders Resources/AppIcon.icns: a viewfinder with a centered focus dot (the app's whole point).
// Usage: swift scripts/make-icon.swift <output.icns>
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources/AppIcon.icns")
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("Focal-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    // Apple grid: 824/1024 body, centered.
    let inset = s * 100 / 1024
    let body = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let shape = NSBezierPath(roundedRect: body, xRadius: body.width * 0.225, yRadius: body.width * 0.225)
    NSGradient(colors: [NSColor(srgbRed: 0.05, green: 0.11, blue: 0.22, alpha: 1),
                        NSColor(srgbRed: 0.08, green: 0.36, blue: 0.62, alpha: 1)])!.draw(in: shape, angle: 90)
    // Viewfinder corners.
    NSColor.white.setStroke()
    let frame = body.insetBy(dx: body.width * 0.2, dy: body.width * 0.2)
    let arm = frame.width * 0.26
    let corners = NSBezierPath()
    corners.lineWidth = s * 0.045
    corners.lineCapStyle = .round
    corners.lineJoinStyle = .round
    for (x, y, dx, dy) in [(frame.minX, frame.minY, 1.0, 1.0), (frame.maxX, frame.minY, -1.0, 1.0),
                           (frame.minX, frame.maxY, 1.0, -1.0), (frame.maxX, frame.maxY, -1.0, -1.0)] {
        corners.move(to: NSPoint(x: x + dx * arm, y: y))
        corners.line(to: NSPoint(x: x, y: y))
        corners.line(to: NSPoint(x: x, y: y + dy * arm))
    }
    corners.stroke()
    // Focus dot dead center.
    let r = s * 0.075
    NSColor(srgbRed: 1, green: 0.62, blue: 0.2, alpha: 1).setFill()
    NSBezierPath(ovalIn: NSRect(x: s / 2 - r, y: s / 2 - r, width: 2 * r, height: 2 * r)).fill()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try render(base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", out.path]
try p.run()
p.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
print(p.terminationStatus == 0 ? "wrote \(out.path)" : "iconutil failed")
