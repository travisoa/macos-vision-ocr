import XCTest
@testable import OCR
import Foundation
import CoreGraphics
import ImageIO
import PDFKit
import CoreText

private func geometryDocument(origin: CGPoint = .zero, rotation: Int = 0, text: Bool = false) throws -> PDFDocument {
    let data = NSMutableData()
    var box = CGRect(origin: origin, size: CGSize(width: 200, height: 100))
    let consumer = CGDataConsumer(data: data as CFMutableData)!
    let context = CGContext(consumer: consumer, mediaBox: &box, nil)!
    context.beginPDFPage(nil)
    context.setFillColor(gray: 0, alpha: 1)
    if text {
        context.textPosition = CGPoint(x: origin.x + 40, y: origin.y + 50)
        let font = CTFontCreateWithName("Helvetica" as CFString, 12, nil)
        let string = NSAttributedString(string: "HELLO", attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
        CTLineDraw(CTLineCreateWithAttributedString(string), context)
    } else {
        context.fill(CGRect(x: origin.x + 10, y: origin.y + 10, width: 20, height: 30))
    }
    context.endPDFPage()
    context.closePDF()
    let document = PDFDocument(data: data as Data)!
    document.page(at: 0)!.rotation = rotation
    return document
}

private func geometryInk(_ image: CGImage) -> (count: Int, bounds: [Int]) {
    let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                            bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    let bytes = context.data!.assumingMemoryBound(to: UInt8.self)
    var count = 0, minX = image.width, minY = image.height, maxX = -1, maxY = -1
    for y in 0..<image.height {
        for x in 0..<image.width where bytes[y * context.bytesPerRow + x * 4] < 128 {
            count += 1
            minX = min(x, minX); maxX = max(x, maxX)
            minY = min(y, minY); maxY = max(y, maxY)
        }
    }
    return (count, [minX, minY, maxX + 1, maxY + 1])
}

private func geometryImageSource(orientation: Int) -> CGImageSource {
    let context = CGContext(data: nil, width: 4, height: 3, bitsPerComponent: 8, bytesPerRow: 16,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    context.setFillColor(gray: 1, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: 4, height: 3))
    context.setFillColor(gray: 0, alpha: 1)
    context.fill(CGRect(x: 0, y: 2, width: 1, height: 1))
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data as CFMutableData, "public.tiff" as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, [kCGImagePropertyOrientation: orientation] as CFDictionary)
    precondition(CGImageDestinationFinalize(destination))
    return CGImageSourceCreateWithData(data as CFData, nil)!
}

final class GeometryTests: XCTestCase {
    func testGeometry() throws {
        var options = Options()
        options.dpi = 72
        let expected = [[10, 60, 30, 90], [10, 10, 40, 30], [170, 10, 190, 40], [60, 170, 90, 190]]
        for origin in [CGPoint.zero, CGPoint(x: 50, y: 60)] {
            for (index, rotation) in [0, 90, 180, 270].enumerated() {
                let document = try geometryDocument(origin: origin, rotation: rotation)
                let raster = try renderPDFPage(document.page(at: 0)!, options: options)
                let ink = geometryInk(raster.image)
                try expect(ink.count == 600 && ink.bounds == expected[index], "PDF native rotation/origin geometry: \(origin) \(rotation): \(ink)")
                try expect(raster.width == (rotation % 180 == 0 ? 200 : 100), "PDF oriented width")
                try expect(raster.height == (rotation % 180 == 0 ? 100 : 200), "PDF oriented height")
                options.rotation = 90
                let extra = try renderPDFPage(document.page(at: 0)!, options: options)
                try expect(geometryInk(extra.image).bounds == expected[(index + 1) % 4], "PDF extra clockwise rotation")
                options.rotation = 0
            }
        }
        let document = try geometryDocument(origin: CGPoint(x: 50, y: 60))
        let page = document.page(at: 0)!
        page.setBounds(CGRect(x: 55, y: 65, width: 100, height: 60), for: .cropBox)
        options.pageBox = .crop
        let crop = try renderPDFPage(page, options: options)
        try expect(crop.width == 100 && crop.height == 60, "CropBox dimensions")
        try expect(geometryInk(crop.image).bounds == [5, 25, 25, 55], "CropBox coordinate transform")
        options.pageBox = .media
        options.region = [0, 0.5, 0.5, 0.5]
        let roi = try renderPDFPage(page, options: options)
        try expect(roi.image.width == 100 && roi.image.height == 50 && roi.offsetX == 0 && roi.offsetY == 50, "ROI full-page offsets")
        try expect(geometryInk(roi.image).bounds == [10, 10, 30, 40], "ROI pixel crop uses top-left origin")
        options.region = nil
        options.dpi = 100.3
        let fractional = try renderPDFPage(page, options: options)
        try expect(fractional.scaleX == Double(fractional.image.width) / 200 && fractional.scaleY == Double(fractional.image.height) / 100, "PDF scales use actual raster dimensions")
        for invalidDPI in [Double.nan, Double.infinity, -1, 0, 100_000] {
            options.dpi = invalidDPI
            var rejected = false
            do { _ = try renderPDFPage(page, options: options) } catch { rejected = true }
            try expect(rejected, "Invalid or excessive DPI must throw before allocation")
        }
        options = Options()
        let locations = [(0, 0), (3, 0), (3, 2), (0, 2), (0, 0), (2, 0), (2, 3), (0, 3)]
        for orientation in 1...8 {
            let source = geometryImageSource(orientation: orientation)
            let raster = try loadImageFrame(source, index: 0, options: options)
            let (x, y) = locations[orientation - 1]
            try expect(geometryInk(raster.image).bounds == [x, y, x + 1, y + 1], "EXIF orientation \(orientation) including mirror")
            try expect(raster.sourceOrientation == orientation, "EXIF source orientation metadata")
            options.rotation = 90
            let rotated = try loadImageFrame(source, index: 0, options: options)
            let rx = Int(raster.height) - 1 - y, ry = x
            try expect(geometryInk(rotated.image).bounds == [rx, ry, rx + 1, ry + 1], "EXIF + user clockwise rotation \(orientation)")
            options.rotation = 0
        }
        let textDoc = try geometryDocument(origin: CGPoint(x: 50, y: 60), text: true)
        let textPage = textDoc.page(at: 0)!
        let extracted = try extractPDFText(textPage, index: 7, options: options)
        try expect(extracted.page == 7 && extracted.lines.map(\.text).joined().contains("HELLO"), "PDF text layer extraction keeps source page")
        let base = extracted.lines.first!.bbox
        options.rotation = 90
        let rotatedText = try extractPDFText(textPage, index: 7, options: options)
        try expect(rotatedText.lines.count == extracted.lines.count, "Rotated text line count")
        let target = [100 - base[3], base[0], 100 - base[1], base[2]]
        try expect(zip(rotatedText.lines[0].bbox, target).allSatisfy { abs($0 - $1) < 0.01 }, "Text bbox maps through same clockwise transform")
        options.rotation = 0
        textPage.rotation = 90
        let nativeRotatedText = try extractPDFText(textPage, index: 7, options: options)
        try expect(nativeRotatedText.lines.count == extracted.lines.count, "Native rotated text line count")
        try expect(zip(nativeRotatedText.lines[0].bbox, target).allSatisfy { abs($0 - $1) < 0.01 }, "Native Rotate text mapping")

        textPage.rotation = 0
        textPage.setBounds(CGRect(x: 55, y: 65, width: 100, height: 60), for: .cropBox)
        options.pageBox = .crop
        let croppedText = try extractPDFText(textPage, index: 7, options: options)
        try expect(croppedText.lines.count == 1, "CropBox retains contained text")
        let cropTarget = [base[0] - 5, base[1] - 35, base[2] - 5, base[3] - 35]
        try expect(zip(croppedText.lines[0].bbox, cropTarget).allSatisfy { abs($0 - $1) < 0.01 }, "CropBox text coordinates")
        options.rotation = 90
        let turnedCropText = try extractPDFText(textPage, index: 7, options: options)
        let turnedCropTarget = [60 - cropTarget[3], cropTarget[0], 60 - cropTarget[1], cropTarget[2]]
        try expect(turnedCropText.lines.count == 1 && zip(turnedCropText.lines[0].bbox, turnedCropTarget).allSatisfy { abs($0 - $1) < 0.01 }, "CropBox plus user rotation text coordinates")
        options.rotation = 0
        options.pageBox = .media
        options.region = [0, 0, 0.25, 1]
        let partialText = try extractPDFText(textPage, index: 7, options: options)
        try expect(partialText.lines.isEmpty && !partialText.warnings.isEmpty, "Partial ROI text line is omitted with explanation")
        options.region = nil

        let unordered = [
            OCRLine(bbox: [100, 0, 110, 10], text: "A", sourceIndex: 10),
            OCRLine(bbox: [0, 8, 10, 28], text: "B", sourceIndex: 11),
            OCRLine(bbox: [50, 5, 60, 15], text: "C", sourceIndex: 12)
        ]
        try expect(sortReadingOrder(unordered, order: .vision).map(\.text) == ["A", "B", "C"], "Vision order is preserved")
        let row = sortReadingOrder(unordered, order: .row)
        try expect(Set(row.map(\.sourceIndex)) == Set([10, 11, 12]), "Row order preserves provenance")
        for permutation in [unordered.reversed().map { $0 }, [unordered[1], unordered[2], unordered[0]]] {
            try expect(sortReadingOrder(permutation, order: .row).map(\.text) == row.map(\.text), "Row clustering deterministic for former comparator counterexamples")
        }
        let columns = [
            OCRLine(bbox: [0, 0, 300, 10], text: "Title"),
            OCRLine(bbox: [0, 20, 90, 30], text: "L1"),
            OCRLine(bbox: [200, 20, 290, 30], text: "R1"),
            OCRLine(bbox: [0, 40, 90, 50], text: "L2"),
            OCRLine(bbox: [200, 40, 290, 50], text: "R2")
        ]
        try expect(sortReadingOrder(columns, order: .row).map(\.text) == ["Title", "L1", "R1", "L2", "R2"], "Row order")
        try expect(sortReadingOrder(columns, order: .column).map(\.text) == ["Title", "L1", "L2", "R1", "R2"], "Columns with spanning heading")
    }
}
