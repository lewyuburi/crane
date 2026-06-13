#!/usr/bin/env swift
// Renders Crane's app icon (a shipping box on a blue rounded square) into the
// .iconset directory passed as the first argument. Used by bundle.sh.
import AppKit

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Crane.iconset"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let size = NSSize(width: px, height: px)
    let image = NSImage(size: size)
    image.lockFocus()

    // Rounded blue background with a subtle vertical gradient.
    let inset = CGFloat(px) * 0.06
    let rect = NSRect(x: inset, y: inset, width: CGFloat(px) - 2 * inset, height: CGFloat(px) - 2 * inset)
    let path = NSBezierPath(roundedRect: rect, xRadius: CGFloat(px) * 0.22, yRadius: CGFloat(px) * 0.22)
    let gradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.20, green: 0.52, blue: 1.0, alpha: 1),
        NSColor(calibratedRed: 0.09, green: 0.32, blue: 0.85, alpha: 1),
    ])
    gradient?.draw(in: path, angle: -90)

    // White shipping-box glyph centered.
    let cfg = NSImage.SymbolConfiguration(pointSize: CGFloat(px) * 0.5, weight: .semibold)
        .applying(.init(paletteColors: [.white]))
    if let sym = NSImage(systemSymbolName: "shippingbox.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(cfg) {
        let s = sym.size
        sym.draw(in: NSRect(x: (CGFloat(px) - s.width) / 2,
                            y: (CGFloat(px) - s.height) / 2,
                            width: s.width, height: s.height))
    }

    image.unlockFocus()
    let tiff = image.tiffRepresentation!
    let rep = NSBitmapImageRep(data: tiff)!
    return rep.representation(using: .png, properties: [:])!
}

let specs: [(name: String, px: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

for spec in specs {
    let data = render(spec.px)
    try! data.write(to: URL(fileURLWithPath: "\(outDir)/\(spec.name).png"))
}
print("wrote \(specs.count) icon images to \(outDir)")
