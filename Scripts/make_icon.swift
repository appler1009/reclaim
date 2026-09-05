// Generates Reclaim's app icon: a dark treemap with one ember-hot tile.
import AppKit

// Two shapes of the same artwork. macOS wants a rounded square with the corners
// already cut and everything outside them transparent; iOS wants a full-bleed
// opaque square and applies its own mask, and refuses an icon with any alpha at
// all. So: `make_icon.swift <dir>` writes the iconset, and
// `make_icon.swift <file.png> --ios` writes the one 1024 square iOS wants.
let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Reclaim.iconset"
let wantsIOS = CommandLine.arguments.contains("--ios")
if !wantsIOS {
    try? FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
}

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
    // The app's "other" slate rather than near-black: at icon size a very dark
    // tile reads as a hole punched in the artwork.
    Tile(x: 0.66, y: 0.58, w: 0.34, h: 0.42, color: NSColor(srgbRed: 0.45, green: 0.50, blue: 0.60, alpha: 1)),
]

func render(size: Int, rounded: Bool = true) -> Data? {
    let dimension = CGFloat(size)
    guard let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: rounded
                                      ? CGImageAlphaInfo.premultipliedLast.rawValue
                                      : CGImageAlphaInfo.noneSkipLast.rawValue)
    else { return nil }

    // The tiles are the icon: they run to the edge of the rounded square, with no
    // frame or backing colour around them, and they meet each other exactly — the
    // same way the map inside the app does.
    let board = CGRect(x: 0, y: 0, width: dimension, height: dimension)
    if rounded {
        let radius = dimension * 0.22
        context.addPath(CGPath(roundedRect: board, cornerWidth: radius, cornerHeight: radius,
                               transform: nil))
        context.clip()
    }

    for tile in tiles {
        let rect = CGRect(x: tile.x * board.width,
                          y: tile.y * board.height,
                          width: tile.w * board.width,
                          height: tile.h * board.height)
        context.setFillColor(tile.color.cgColor)
        context.fill(rect)

        // The same inside-the-tile shading the map draws, so edges read as edges
        // without carving space out between them.
        let edge = max(1, dimension * 0.006)
        context.setFillColor(NSColor(white: 1, alpha: 0.14).cgColor)
        context.fill(CGRect(x: rect.minX, y: rect.maxY - edge, width: rect.width, height: edge))
        context.setFillColor(NSColor(white: 0, alpha: 0.16).cgColor)
        context.fill(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: edge))
    }

    guard let image = context.makeImage() else { return nil }
    let rep = NSBitmapImageRep(cgImage: image)
    return rep.representation(using: .png, properties: [:])
}

if wantsIOS {
    if let data = render(size: 1024, rounded: false) {
        try? data.write(to: URL(fileURLWithPath: output))
        print("iOS icon written to \(output)")
    }
} else {
    for (size, name) in [(16, "16x16"), (32, "16x16@2x"), (32, "32x32"), (64, "32x32@2x"),
                         (128, "128x128"), (256, "128x128@2x"), (256, "256x256"),
                         (512, "256x256@2x"), (512, "512x512"), (1024, "512x512@2x")] {
        if let data = render(size: size) {
            try? data.write(to: URL(fileURLWithPath: "\(output)/icon_\(name).png"))
        }
    }
    print("icon written to \(output)")
}
