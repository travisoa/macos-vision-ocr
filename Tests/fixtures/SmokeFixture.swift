import Foundation
import AppKit
import CoreGraphics
import ImageIO
import PDFKit

let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
let width = 1200, height = 900
let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                        bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
context.setFillColor(CGColor(gray: 1, alpha: 1))
context.fill(CGRect(x: 0, y: 0, width: width, height: height))
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
func label(_ value: String, _ x: Int, _ y: Int, size: CGFloat = 34) {
    (value as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: [
        .font: NSFont.systemFont(ofSize: size), .foregroundColor: NSColor.black
    ])
}
label("GB/T 7258  Vehicle Specification", 70, 790, size: 42)
label("车辆识别代号  LNB1DN2K123456789", 70, 710)
context.setStrokeColor(CGColor(gray: 0, alpha: 1))
context.setLineWidth(3)
for y in [200, 310, 420, 530, 640] {
    context.move(to: CGPoint(x: 70, y: y)); context.addLine(to: CGPoint(x: 1130, y: y))
}
for x in [70, 600, 1130] {
    context.move(to: CGPoint(x: x, y: 200)); context.addLine(to: CGPoint(x: x, y: 640))
}
context.strokePath()
for (index, pair) in [("Parameter", "Value"), ("Length", "4520 mm"), ("Width", "1850 mm"), ("Maximum mass", "2100 kg")].enumerated() {
    label(pair.0, 100, 570 - index * 110)
    label(pair.1, 650, 570 - index * 110)
}
NSGraphicsContext.restoreGraphicsState()
let image = context.makeImage()!
let destination = CGImageDestinationCreateWithURL(directory.appendingPathComponent("sample.png") as CFURL,
                                                  "public.png" as CFString, 1, nil)!
CGImageDestinationAddImage(destination, image, nil)
assert(CGImageDestinationFinalize(destination))
var media = CGRect(x: 0, y: 0, width: 600, height: 450)
let pdf = CGContext(directory.appendingPathComponent("scanned.pdf") as CFURL, mediaBox: &media, nil)!
for _ in 0..<2 {
    pdf.beginPDFPage(nil)
    pdf.draw(image, in: media)
    pdf.endPDFPage()
}
pdf.closePDF()
let document = PDFDocument(url: directory.appendingPathComponent("scanned.pdf"))!
document.page(at: 1)!.rotation = 90
assert(document.write(to: directory.appendingPathComponent("scanned.pdf")))
print(directory.path)
