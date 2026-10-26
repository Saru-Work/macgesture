// Renders the app icon into an .iconset directory.
// Usage: swift scripts/make-icon.swift <output.iconset>
import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "AppIcon.iconset")
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func render(_ pixels: Int) -> Data? {
    let size = CGFloat(pixels)
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // macOS icon grid: 824/1024 body with ~185/1024 corner radius.
    let inset = size * 100 / 1024
    let body = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let path = NSBezierPath(roundedRect: body, xRadius: size * 185 / 1024, yRadius: size * 185 / 1024)
    NSGradient(colors: [
        NSColor(calibratedRed: 0.36, green: 0.42, blue: 0.98, alpha: 1),
        NSColor(calibratedRed: 0.55, green: 0.27, blue: 0.86, alpha: 1),
    ])?.draw(in: path, angle: -60)

    let configuration = NSImage.SymbolConfiguration(pointSize: size * 0.42, weight: .medium)
        .applying(.init(paletteColors: [.white]))
    if let symbol = NSImage(systemSymbolName: "hand.point.up.left.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(configuration) {
        let symbolSize = symbol.size
        symbol.draw(in: NSRect(x: (size - symbolSize.width) / 2, y: (size - symbolSize.height) / 2,
                               width: symbolSize.width, height: symbolSize.height))
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        guard let data = render(points * scale) else { fatalError("Could not render \(name)") }
        try data.write(to: output.appendingPathComponent(name))
    }
}
