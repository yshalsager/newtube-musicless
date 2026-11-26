// Renders the iOS app icon (1024 px, opaque PNG) from the Android fork's adaptive icon
// vectors, smarttubetv/src/musicless/res/drawable/ic_launcher_{background,foreground}.xml.
//
//   swift ios/tools/render_app_icon.swift ios/App/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png
//
// The vectors use a 108-unit viewport of which launchers show the middle 72 units (18...90);
// that region fills the iOS icon, and iOS applies its own corner mask.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = 1024
let visible: CGFloat = 72, inset: CGFloat = 18
guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: render_app_icon.swift <out.png>\n".utf8))
    exit(2)
}

func color(_ hex: UInt32) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}

let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
// Vector space: y down, 108-unit viewport, visible region scaled to the full bitmap.
context.translateBy(x: 0, y: CGFloat(size))
context.scaleBy(x: CGFloat(size) / visible, y: -CGFloat(size) / visible)
context.translateBy(x: -inset, y: -inset)

// Background: emerald square, darker lower-right triangle.
context.setFillColor(color(0x0E6B52))
context.fill(CGRect(x: 0, y: 0, width: 108, height: 108))
context.setFillColor(color(0x0A5340))
context.move(to: CGPoint(x: 108, y: 0))
context.addLine(to: CGPoint(x: 108, y: 108))
context.addLine(to: CGPoint(x: 0, y: 108))
context.closePath()
context.fillPath()

// The NewTube arch ("n"): M32,76 L32,53 A22,22 0 0 1 76,53 L76,76 L63,76 L63,53 A9,9 0 0 0 45,53 L45,76 Z
let arch = CGMutablePath()
arch.move(to: CGPoint(x: 32, y: 76))
arch.addLine(to: CGPoint(x: 32, y: 53))
arch.addArc(center: CGPoint(x: 54, y: 53), radius: 22, startAngle: .pi, endAngle: 2 * .pi, clockwise: false)
arch.addLine(to: CGPoint(x: 76, y: 76))
arch.addLine(to: CGPoint(x: 63, y: 76))
arch.addLine(to: CGPoint(x: 63, y: 53))
arch.addArc(center: CGPoint(x: 54, y: 53), radius: 9, startAngle: 2 * .pi, endAngle: .pi, clockwise: true)
arch.addLine(to: CGPoint(x: 45, y: 76))
arch.closeSubpath()
context.setFillColor(color(0xFFFFFF))
context.setStrokeColor(color(0xFFFFFF))
context.setLineWidth(5)
context.setLineJoin(.round)
context.setLineCap(.round)
context.addPath(arch)
context.drawPath(using: .fillStroke)

// Gold voice bars (2.6 wide, 1.3 corner radius).
context.setFillColor(color(0xF4C542))
for (x, top) in [(48.4, 62.0), (52.7, 57.0), (57.0, 62.0)] as [(CGFloat, CGFloat)] {
    let bar = CGRect(x: x, y: top, width: 2.6, height: 71 - top)
    context.addPath(CGPath(roundedRect: bar, cornerWidth: 1.3, cornerHeight: 1.3, transform: nil))
}
context.fillPath()

let url = URL(fileURLWithPath: CommandLine.arguments[1])
let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(destination, context.makeImage()!, nil)
guard CGImageDestinationFinalize(destination) else { exit(1) }
print("wrote \(url.path)")
