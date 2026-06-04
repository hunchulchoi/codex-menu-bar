import AppKit
import Foundation

guard CommandLine.arguments.count >= 3 else {
    print("Usage: swift make-icns.swift <input.svg> <output.icns>")
    exit(1)
}

let inputPath = CommandLine.arguments[1]
let outputPath = CommandLine.arguments[2]

let svgURL = URL(fileURLWithPath: inputPath)
guard let svgImage = NSImage(contentsOf: svgURL) else {
    print("Failed to load SVG from \(inputPath)")
    exit(1)
}

let iconsetDir = outputPath.replacingOccurrences(of: ".icns", with: ".iconset")
try? FileManager.default.createDirectory(atPath: iconsetDir, withIntermediateDirectories: true)

let sizes = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

for (filename, size) in sizes {
    let destSize = NSSize(width: size, height: size)
    let newImage = NSImage(size: destSize)
    
    newImage.lockFocus()
    NSGraphicsContext.current?.imageInterpolation = .high
    
    // Fill background with #111827 (macOS app icon squircle style)
    let path = NSBezierPath(roundedRect: NSRect(origin: .zero, size: destSize), xRadius: CGFloat(size) * 0.22, yRadius: CGFloat(size) * 0.22)
    NSColor(red: 0.067, green: 0.094, blue: 0.153, alpha: 1.0).setFill() // #111827
    path.fill()
    
    // Draw white SVG in center, slightly smaller to fit nicely in the squircle
    let padding = CGFloat(size) * 0.15
    let drawRect = NSRect(x: padding, y: padding, width: CGFloat(size) - padding * 2, height: CGFloat(size) - padding * 2)
    
    svgImage.isTemplate = true
    NSColor.white.set()
    svgImage.draw(in: drawRect, from: .zero, operation: .sourceOver, fraction: 1.0)
    
    newImage.unlockFocus()
    
    guard let tiffData = newImage.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiffData),
          let pngData = bitmap.representation(using: .png, properties: [:]) else {
        print("Failed to convert image to PNG for size \(size)")
        exit(1)
    }
    
    let destPath = (iconsetDir as NSString).appendingPathComponent(filename)
    try? pngData.write(to: URL(fileURLWithPath: destPath))
}

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconsetDir]
do {
    try process.run()
    process.waitUntilExit()
} catch {
    print("Failed to run iconutil: \(error)")
    exit(1)
}

try? FileManager.default.removeItem(atPath: iconsetDir)
print("Successfully generated \(outputPath)")
