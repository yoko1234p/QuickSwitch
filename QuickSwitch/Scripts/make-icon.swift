import AppKit

let destination = CommandLine.arguments[1]
let set = URL(fileURLWithPath: destination).appendingPathComponent("QuickSwitch.iconset")
try FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
for (name, size) in [
    ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64), ("icon_128x128", 128),
    ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512), ("icon_512x512", 512),
    ("icon_512x512@2x", 1024),
] {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let edge = CGFloat(size)
    let rect = NSRect(x: 0, y: 0, width: edge, height: edge)
    let tile = NSBezierPath(
        roundedRect: rect.insetBy(dx: edge * 0.055, dy: edge * 0.055), xRadius: edge * 0.21, yRadius: edge * 0.21)
    NSGradient(
        starting: NSColor(calibratedRed: 0.95, green: 0.98, blue: 1, alpha: 1),
        ending: NSColor(calibratedRed: 0.68, green: 0.82, blue: 1, alpha: 1))!.draw(in: tile, angle: -90)
    NSColor.white.withAlphaComponent(0.7).setStroke()
    tile.lineWidth = max(0.7, edge * 0.005)
    tile.stroke()
    let track = NSRect(x: edge * 0.16, y: edge * 0.32, width: edge * 0.68, height: edge * 0.36)
    let trackPath = NSBezierPath(roundedRect: track, xRadius: track.height / 2, yRadius: track.height / 2)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.systemBlue.withAlphaComponent(0.22)
    shadow.shadowBlurRadius = edge * 0.035
    shadow.shadowOffset = NSSize(width: 0, height: -edge * 0.02)
    shadow.set()
    NSColor(calibratedRed: 0.03, green: 0.42, blue: 0.95, alpha: 1).setFill()
    trackPath.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSColor.white.setFill()
    let knob = edge * 0.25
    NSBezierPath(
        ovalIn: NSRect(x: track.maxX - knob - edge * 0.055, y: track.midY - knob / 2, width: knob, height: knob)
    ).fill()
    NSGraphicsContext.restoreGraphicsState()
    try rep.representation(using: .png, properties: [:])!.write(to: set.appendingPathComponent(name + ".png"))
}
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = [
    "-c", "icns", set.path, "-o", URL(fileURLWithPath: destination).appendingPathComponent("QuickSwitch.icns").path,
]
try task.run()
task.waitUntilExit()
guard task.terminationStatus == 0 else { exit(1) }
try FileManager.default.removeItem(at: set)
