import AppKit
func render(_ symbol: String, pointSize: CGFloat, offset: CGPoint, to path: String) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: 1024, height: 1024)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold).applying(.init(paletteColors: [.white]))
    if let glyph = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config) {
        let g = glyph.size
        glyph.draw(in: NSRect(x: (1024 - g.width) / 2 + offset.x, y: (1024 - g.height) / 2 + offset.y, width: g.width, height: g.height))
    }
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}
render("tv.fill", pointSize: 430, offset: CGPoint(x: 0, y: -12), to: CommandLine.arguments[1])
render("play.fill", pointSize: 180, offset: CGPoint(x: 1, y: 25), to: CommandLine.arguments[2])
