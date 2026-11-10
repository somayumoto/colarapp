import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Run on macOS: xcrun swift Design/generate-app-icons.swift
// Draw each size from vector geometry, with an opaque sRGB background.
let repository = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
let output = repository.appendingPathComponent("色々変え/Assets.xcassets/AppIcon.appiconset")
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func color(_ hex: UInt32) -> CGColor {
    CGColor(
        colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
        components: [
            CGFloat((hex >> 16) & 255) / 255,
            CGFloat((hex >> 8) & 255) / 255,
            CGFloat(hex & 255) / 255,
            1
        ]
    )!
}

func render(pixels: Int) throws {
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(
            data: nil, width: pixels, height: pixels,
            bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
          ) else { fatalError("Could not create opaque RGB icon context") }

    context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    context.setAllowsAntialiasing(true)
    context.setShouldAntialias(true)
    context.setFillColor(color(0x10182B))
    context.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024))

    // Camera-viewfinder corners frame the red input and blue output.
    context.setStrokeColor(color(0xFFFFFF))
    context.setLineWidth(22)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    let corners: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [
        (152, 224, 1, 1), (872, 224, -1, 1),
        (152, 800, 1, -1), (872, 800, -1, -1)
    ]
    for (x, y, dx, dy) in corners {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: x, y: y + dy * 124))
        path.addLine(to: CGPoint(x: x, y: y + dy * 44))
        path.addQuadCurve(
            to: CGPoint(x: x + dx * 44, y: y),
            control: CGPoint(x: x, y: y)
        )
        path.addLine(to: CGPoint(x: x + dx * 124, y: y))
        context.addPath(path)
        context.strokePath()
    }

    context.setFillColor(color(0xF25362))
    context.fillEllipse(in: CGRect(x: 190, y: 392, width: 240, height: 240))
    context.setFillColor(color(0x477CFF))
    context.fillEllipse(in: CGRect(x: 594, y: 392, width: 240, height: 240))

    // A single arrow communicates red → blue, rather than channel swapping.
    context.setLineWidth(20)
    context.move(to: CGPoint(x: 454, y: 512))
    context.addLine(to: CGPoint(x: 576, y: 512))
    context.strokePath()
    context.move(to: CGPoint(x: 544, y: 548))
    context.addLine(to: CGPoint(x: 580, y: 512))
    context.addLine(to: CGPoint(x: 544, y: 476))
    context.strokePath()

    let filename = output.appendingPathComponent("AppIcon-\(pixels).png")
    guard let image = context.makeImage(),
          let destination = CGImageDestinationCreateWithURL(
            filename as CFURL, UTType.png.identifier as CFString, 1, nil
          ) else { fatalError("Could not create PNG destination for \(pixels)px icon") }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        fatalError("Could not write \(filename.path)")
    }
}

struct IconSlot: Encodable {
    let idiom: String
    let size: String
    let scale: String
    let filename: String
}

var slots: [IconSlot] = []
var dimensions: Set<Int> = []
func add(idiom: String, points: Double, scale: Int) {
    let pixels = Int(points * Double(scale))
    let size = points.rounded() == points ? String(Int(points)) : String(points)
    slots.append(IconSlot(
        idiom: idiom, size: "\(size)x\(size)", scale: "\(scale)x",
        filename: "AppIcon-\(pixels).png"
    ))
    dimensions.insert(pixels)
}

for points in [20.0, 29, 40, 60] {
    for scale in [2, 3] { add(idiom: "iphone", points: points, scale: scale) }
}
for points in [20.0, 29, 40, 76] {
    for scale in [1, 2] { add(idiom: "ipad", points: points, scale: scale) }
}
add(idiom: "ipad", points: 83.5, scale: 2)
add(idiom: "ios-marketing", points: 1024, scale: 1)
for pixels in dimensions.sorted() { try render(pixels: pixels) }

struct Catalog: Encodable {
    struct Info: Encodable {
        let author = "xcode"
        let version = 1
    }
    let images: [IconSlot]
    let info = Info()
}
let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
let data = try encoder.encode(Catalog(images: slots))
try (data + Data([0x0A])).write(to: output.appendingPathComponent("Contents.json"))
print("Generated \(dimensions.count) opaque RGB PNGs for \(slots.count) AppIcon slots in \(output.path)")
