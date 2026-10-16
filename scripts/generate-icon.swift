import AppKit
import ImageIO

let root = URL(fileURLWithPath: CommandLine.arguments[1])
let context = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
context.setFillColor(CGColor(red: 0.055, green: 0.063, blue: 0.067, alpha: 1))
context.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024))
context.setFillColor(CGColor(red: 0.94, green: 0.69, blue: 0.37, alpha: 1))
for (index, height) in [180.0, 340, 520, 390, 230].enumerated() {
    let rect = CGRect(x: 232 + Double(index) * 116, y: (1024 - height) / 2, width: 72, height: height)
    context.addPath(CGPath(roundedRect: rect, cornerWidth: 36, cornerHeight: 36, transform: nil))
    context.fillPath()
}
let url = root.appendingPathComponent("Sonora/Assets.xcassets/AppIcon.appiconset/AppIcon.png")
try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
CGImageDestinationAddImage(destination, context.makeImage()!, nil)
precondition(CGImageDestinationFinalize(destination))
