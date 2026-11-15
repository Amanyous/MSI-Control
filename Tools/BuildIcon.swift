import AppKit

// Convert the approved opaque concept into a transparent, multi-resolution app icon.
guard CommandLine.arguments.count == 3,
      let image = NSImage(contentsOfFile: CommandLine.arguments[1]) else {
    fatalError("Usage: swift Tools/BuildIcon.swift master.png output.iconset")
}
let output = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

let sizes: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024)
]
for (name, pixels) in sizes {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
        isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        fatalError("Cannot create icon bitmap")
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    let scale = CGFloat(pixels)
    // Match the approved artwork's silhouette; discard its white presentation canvas.
    let bounds = CGRect(x: scale * 0.109, y: scale * 0.118,
                        width: scale * 0.782, height: scale * 0.762)
    let outline = NSBezierPath()
    for step in 0...720 {
        let angle = Double(step) * .pi / 360
        let cosine = cos(angle)
        let sine = sin(angle)
        let x = copysign(pow(abs(cosine), 2 / 4.4), cosine)
        let y = copysign(pow(abs(sine), 2 / 4.4), sine)
        let point = CGPoint(x: bounds.midX + bounds.width / 2 * x,
                            y: bounds.midY + bounds.height / 2 * y)
        if step == 0 { outline.move(to: point) } else { outline.line(to: point) }
    }
    outline.close()
    outline.addClip()
    image.draw(in: CGRect(x: 0, y: 0, width: scale, height: scale),
               from: .zero, operation: .copy, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        fatalError("Cannot encode icon")
    }
    try png.write(to: output.appendingPathComponent(name + ".png"))
}
