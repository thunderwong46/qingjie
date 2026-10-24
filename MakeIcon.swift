import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// Vector-drawn icon: translucent green tile, white crop frame, bright capture point.
func makeIcon(size: Int, url: URL) throws {
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    let c = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    let tile = CGRect(x: 60, y: 60, width: 904, height: 904)
    let shape = CGPath(roundedRect: tile, cornerWidth: 204, cornerHeight: 204, transform: nil)
    c.saveGState()
    c.setShadow(offset: CGSize(width: 0, height: -10), blur: 23, color: CGColor(red: 0, green: 0.16, blue: 0.09, alpha: 0.25))
    c.addPath(shape); c.setFillColor(CGColor(red: 0.02, green: 0.55, blue: 0.28, alpha: 1)); c.fillPath()
    c.restoreGState()
    c.saveGState(); c.addPath(shape); c.clip()
    let colors = [CGColor(red: 0.25, green: 0.93, blue: 0.44, alpha: 1), CGColor(red: 0.04, green: 0.72, blue: 0.37, alpha: 1), CGColor(red: 0, green: 0.47, blue: 0.31, alpha: 1)] as CFArray
    let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: [0, 0.48, 1])!
    c.drawLinearGradient(gradient, start: CGPoint(x: 170, y: 960), end: CGPoint(x: 900, y: 80), options: [])
    c.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.045))
    c.fillEllipse(in: CGRect(x: -240, y: 420, width: 1110, height: 760))
    c.restoreGState()
    c.addPath(CGPath(roundedRect: tile.insetBy(dx: 2, dy: 2), cornerWidth: 202, cornerHeight: 202, transform: nil))
    c.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.23)); c.setLineWidth(3); c.strokePath()
    c.saveGState()
    c.setShadow(offset: CGSize(width: 0, height: -6), blur: 10, color: CGColor(red: 0, green: 0.28, blue: 0.13, alpha: 0.18))
    c.setStrokeColor(CGColor(gray: 1, alpha: 1)); c.setLineWidth(58); c.setLineCap(.round); c.setLineJoin(.round)
    for (x, y, dx, dy) in [(264.0, 760.0, 1.0, -1.0), (760.0, 760.0, -1.0, -1.0), (264.0, 264.0, 1.0, 1.0), (760.0, 264.0, -1.0, 1.0)] {
        c.move(to: CGPoint(x: x + dx * 128, y: y))
        c.addLine(to: CGPoint(x: x + dx * 34, y: y))
        c.addQuadCurve(to: CGPoint(x: x, y: y + dy * 34), control: CGPoint(x: x, y: y))
        c.addLine(to: CGPoint(x: x, y: y + dy * 128)); c.strokePath()
    }
    c.setFillColor(CGColor(gray: 1, alpha: 1))
    c.fillEllipse(in: CGRect(x: 457, y: 457, width: 110, height: 110))
    c.restoreGState()
    let image = c.makeImage()!
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { throw CocoaError(.fileWriteUnknown) }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
}
let target = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    try makeIcon(size: size, url: target.appendingPathComponent("icon_\(size)x\(size).png"))
    try makeIcon(size: size * 2, url: target.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
