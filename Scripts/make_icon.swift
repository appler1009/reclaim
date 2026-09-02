// Generates Reclaim's app icon: a dark treemap with one ember-hot tile.
import AppKit

let outputDirectory = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Reclaim.iconset"
try? FileManager.default.createDirectory(atPath: outputDirectory,
                                         withIntermediateDirectories: true)

struct Tile { let x, y, w, h: CGFloat; let color: NSColor }
let ember = NSColor(srgbRed: 1.00, green: 0.42, blue: 0.36, alpha: 1)
let tiles: [Tile] = [
    Tile(x: 0.00, y: 0.00, w: 0.52, h: 0.58, color: ember),
    Tile(x: 0.52, y: 0.00, w: 0.48, h: 0.32, color: NSColor(srgbRed: 0.36, green: 0.78, blue: 0.98, alpha: 1)),
    Tile(x: 0.52, y: 0.32, w: 0.26, h: 0.26, color: NSColor(srgbRed: 0.78, green: 0.44, blue: 0.98, alpha: 1)),
    Tile(x: 0.78, y: 0.32, w: 0.22, h: 0.26, color: NSColor(srgbRed: 0.32, green: 0.86, blue: 0.70, alpha: 1)),
    Tile(x: 0.00, y: 0.58, w: 0.32, h: 0.42, color: NSColor(srgbRed: 0.98, green: 0.72, blue: 0.30, alpha: 1)),
    Tile(x: 0.32, y: 0.58, w: 0.34, h: 0.22, color: NSColor(srgbRed: 0.52, green: 0.90, blue: 0.44, alpha: 1)),
    Tile(x: 0.32, y: 0.80, w: 0.34, h: 0.20, color: NSColor(srgbRed: 0.58, green: 0.66, blue: 0.98, alpha: 1)),
    Tile(x: 0.66, y: 0.58, w: 0.34, h: 0.42, color: NSColor(white: 0.32, alpha: 1)),
]

func render(size: Int) -> Data? {
    let dimension = CGFloat(size)
    guard let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }

    let inset = dimension * 0.08
    let board = CGRect(x: inset, y: inset, width: dimension - inset * 2, height: dimension - inset * 2)
    let radius = dimension * 0.22
    let rounded = CGPath(roundedRect: CGRect(x: 0, y: 0, width: dimension, height: dimension),
                         cornerWidth: radius, cornerHeight: radius, transform: nil)
    context.addPath(rounded)
    context.clip()
    context.setFillColor(NSColor(srgbRed: 0.055, green: 0.063, blue: 0.086, alpha: 1).cgColor)
    context.fill(CGRect(x: 0, y: 0, width: dimension, height: dimension))

    let gap = max(1, dimension * 0.012)
    for tile in tiles {
        let rect = CGRect(x: board.minX + tile.x * board.width + gap,
                          y: board.minY + tile.y * board.height + gap,
                          width: tile.w * board.width - gap * 2,
                          height: tile.h * board.height - gap * 2)
        context.setFillColor(tile.color.cgColor)
        context.fill(rect)
        context.setFillColor(NSColor(white: 1, alpha: 0.16).cgColor)
        context.fill(CGRect(x: rect.minX, y: rect.maxY - gap, width: rect.width, height: gap))
    }

    guard let image = context.makeImage() else { return nil }
    let rep = NSBitmapImageRep(cgImage: image)
    return rep.representation(using: .png, properties: [:])
}

for (size, name) in [(16, "16x16"), (32, "16x16@2x"), (32, "32x32"), (64, "32x32@2x"),
                     (128, "128x128"), (256, "128x128@2x"), (256, "256x256"),
                     (512, "256x256@2x"), (512, "512x512"), (1024, "512x512@2x")] {
    if let data = render(size: size) {
        try? data.write(to: URL(fileURLWithPath: "\(outputDirectory)/icon_\(name).png"))
    }
}
print("icon written to \(outputDirectory)")
