#!/usr/bin/env swift

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let iconDirectory = URL(
    fileURLWithPath: "zz/Assets.xcassets/AppIcon.appiconset",
    relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
)

let iconSizes = [16, 32, 64, 128, 256, 512, 1024]

func makeColor(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(red: red, green: green, blue: blue, alpha: alpha)
}

func scaledPoint(_ x: CGFloat, _ y: CGFloat, scale: CGFloat) -> CGPoint {
    CGPoint(x: x * scale, y: y * scale)
}

func makeZPath(_ points: [CGPoint]) -> CGPath {
    let path = CGMutablePath()
    guard let first = points.first else { return path }
    path.move(to: first)
    for point in points.dropFirst() {
        path.addLine(to: point)
    }
    return path
}

func stroke(
    _ path: CGPath,
    in context: CGContext,
    width: CGFloat,
    color: CGColor,
    shadowColor: CGColor? = nil,
    shadowBlur: CGFloat = 0,
    shadowOffset: CGSize = .zero
) {
    context.saveGState()
    if let shadowColor {
        context.setShadow(offset: shadowOffset, blur: shadowBlur, color: shadowColor)
    }
    context.addPath(path)
    context.setLineWidth(width)
    context.setLineCap(.butt)
    context.setLineJoin(.miter)
    context.setMiterLimit(3.5)
    context.setStrokeColor(color)
    context.strokePath()
    context.restoreGState()
}

func makeIcon(size: Int) throws -> CGImage {
    let side = CGFloat(size)
    let scale = side / 1024
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        throw NSError(domain: "IconGenerator", code: 1)
    }

    context.setAllowsAntialiasing(true)
    context.setShouldAntialias(true)
    context.translateBy(x: 0, y: side)
    context.scaleBy(x: 1, y: -1)

    context.setFillColor(makeColor(0.055, 0.06, 0.07))
    context.fill(CGRect(x: 0, y: 0, width: side, height: side))

    func markPoint(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        scaledPoint(x, 1024 - y, scale: scale)
    }

    func visualPoint(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        markPoint(1024 - x, y)
    }

    let largeZ = makeZPath([
        visualPoint(208, 288),
        visualPoint(816, 288),
        visualPoint(208, 736),
        visualPoint(816, 736)
    ])
    let smallZ = makeZPath([
        visualPoint(360, 432),
        visualPoint(621, 432),
        visualPoint(403, 592),
        visualPoint(664, 592)
    ])

    let largeWidth = max(1.1, 30 * scale)
    let smallWidth = max(0.9, 18 * scale)
    let strokeColor = makeColor(0.955, 0.965, 0.97)

    stroke(
        largeZ,
        in: context,
        width: largeWidth,
        color: strokeColor
    )
    stroke(
        smallZ,
        in: context,
        width: smallWidth,
        color: strokeColor
    )

    guard let image = context.makeImage() else {
        throw NSError(domain: "IconGenerator", code: 2)
    }
    return image
}

for size in iconSizes {
    let image = try makeIcon(size: size)
    let outputURL = iconDirectory.appendingPathComponent("AppIcon-\(size).png")
    guard let destination = CGImageDestinationCreateWithURL(
        outputURL as CFURL,
        UTType.png.identifier as CFString,
        1,
        nil
    ) else {
        throw NSError(domain: "IconGenerator", code: 3)
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw NSError(domain: "IconGenerator", code: 4)
    }
}
