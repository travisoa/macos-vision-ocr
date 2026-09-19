import Foundation
import CoreGraphics
import ImageIO
import PDFKit

private let maximumRasterPixels = 100_000_000.0

private func normalizedRotation(_ rotation: Int) throws -> Int {
    guard rotation % 90 == 0 else {
        throw ToolError("invalid_rotation", "旋转角度必须是 90 的整数倍")
    }
    return (rotation % 360 + 360) % 360
}

private func checkedRasterSize(width: Double, height: Double) throws -> (Int, Int) {
    guard width.isFinite, height.isFinite, width > 0, height > 0 else {
        throw ToolError("invalid_page_size", "页面尺寸必须是有限正数")
    }
    let w = ceil(width), h = ceil(height)
    // This also bounds each dimension before conversion to Int.
    guard w <= maximumRasterPixels, h <= maximumRasterPixels,
          w * h <= maximumRasterPixels else {
        throw ToolError("raster_too_large", "单页栅格超过 100 MP，请降低 --dpi 或缩小源图片")
    }
    return (Int(w), Int(h))
}

private func bitmapContext(width: Int, height: Int) throws -> CGContext {
    guard let context = CGContext(data: nil, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
        throw ToolError("raster_allocation_failed", "无法分配页面图像内存")
    }
    context.setFillColor(gray: 1, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return context
}

private func normalizedRegion(_ options: Options, width: Double, height: Double) throws -> CGRect {
    guard let values = options.region else { return CGRect(x: 0, y: 0, width: width, height: height) }
    guard values.count == 4, values.allSatisfy({ $0.isFinite }),
          values[0] >= 0, values[1] >= 0, values[2] > 0, values[3] > 0,
          values[0] + values[2] <= 1, values[1] + values[3] <= 1 else {
        throw ToolError("invalid_region", "--region 必须是页面范围内的归一化 x,y,width,height")
    }
    return CGRect(x: values[0] * width, y: values[1] * height,
                  width: values[2] * width, height: values[3] * height)
}

private func croppedRaster(_ image: CGImage, width: Double, height: Double,
                           unit: String, rotation: Int, sourceOrientation: Int? = nil, options: Options) throws -> RasterPage {
    let scaleX = Double(image.width) / width, scaleY = Double(image.height) / height
    let region = try normalizedRegion(options, width: width, height: height)
    let left = floor(region.minX * scaleX), top = floor(region.minY * scaleY)
    let right = min(Double(image.width), ceil(region.maxX * scaleX))
    let bottom = min(Double(image.height), ceil(region.maxY * scaleY))
    let rect = CGRect(x: left, y: top, width: right - left, height: bottom - top)
    let crop: CGImage
    if options.region == nil {
        crop = image
    } else {
        guard let result = image.cropping(to: rect) else {
            throw ToolError("crop_failed", "无法裁剪指定区域")
        }
        crop = result
    }
    return RasterPage(image: crop, width: width, height: height, unit: unit,
                      rotation: rotation, scaleX: scaleX, scaleY: scaleY,
                      offsetX: left / scaleX, offsetY: top / scaleY, sourceOrientation: sourceOrientation)
}

private struct PDFGeometry {
    let reference: CGPDFPage
    let boxType: CGPDFBox
    let box: CGRect
    let width: Double
    let height: Double
    let rotation: Int
    let additionalRotation: Int

    func drawingTransform(width: Double, height: Double) -> CGAffineTransform {
        reference.getDrawingTransform(boxType,
                                      rect: CGRect(x: 0, y: 0, width: width, height: height),
                                      rotate: Int32(additionalRotation), preserveAspectRatio: false)
    }
}

private func pdfGeometry(_ page: PDFPage, options: Options) throws -> PDFGeometry {
    guard let reference = page.pageRef else {
        throw ToolError("pdf_page_unavailable", "无法读取 PDF 页面")
    }
    let additional = try normalizedRotation(options.rotation)
    let intrinsic = try normalizedRotation(page.rotation)
    let rotation = (intrinsic + additional) % 360
    let boxType: CGPDFBox = options.pageBox == .crop ? .cropBox : .mediaBox
    // CGPDFPage's drawing transform clips the chosen box to the media box.
    let box = reference.getBoxRect(boxType).intersection(reference.getBoxRect(.mediaBox))
    guard !box.isNull, box.width.isFinite, box.height.isFinite,
          box.minX.isFinite, box.minY.isFinite, box.width > 0, box.height > 0 else {
        throw ToolError("invalid_page_size", "PDF 页面框无效")
    }
    let swap = rotation == 90 || rotation == 270
    return PDFGeometry(reference: reference, boxType: boxType, box: box,
                       width: Double(swap ? box.height : box.width),
                       height: Double(swap ? box.width : box.height),
                       rotation: rotation, additionalRotation: additional)
}

func renderPDFPage(_ page: PDFPage, options: Options) throws -> RasterPage {
    let geometry = try pdfGeometry(page, options: options)
    guard options.dpi.isFinite, options.dpi > 0 else {
        throw ToolError("invalid_dpi", "DPI 必须是有限正数")
    }
    let (w, h) = try checkedRasterSize(width: geometry.width * options.dpi / 72,
                                     height: geometry.height * options.dpi / 72)
    let context = try bitmapContext(width: w, height: h)
    context.concatenate(geometry.drawingTransform(width: Double(w), height: Double(h)))
    context.clip(to: geometry.box)
    context.drawPDFPage(geometry.reference)
    guard let image = context.makeImage() else { throw ToolError("pdf_render_failed", "PDF 页面渲染失败") }
    return try croppedRaster(image, width: geometry.width, height: geometry.height,
                             unit: "pt", rotation: geometry.rotation, options: options)
}

// ImageIO returns undecorated image pixels; all eight EXIF orientations,
// including mirrored ones, are explicitly applied in bottom-left CGContext space.
private func exifTransform(_ orientation: Int, width: Double, height: Double)
    -> (CGAffineTransform, Double, Double) {
    switch orientation {
    case 2: return (CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: width, ty: 0), width, height)
    case 3: return (CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: width, ty: height), width, height)
    case 4: return (CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: height), width, height)
    case 5: return (CGAffineTransform(a: 0, b: -1, c: -1, d: 0, tx: height, ty: width), height, width)
    case 6: return (CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: width), height, width)
    case 7: return (CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0), height, width)
    case 8: return (CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: height, ty: 0), height, width)
    default: return (.identity, width, height)
    }
}

func loadImageFrame(_ source: CGImageSource, index: Int, options: Options) throws -> RasterPage {
    guard index >= 0, index < CGImageSourceGetCount(source) else {
        throw ToolError("image_frame_unavailable", "图片帧不存在")
    }
    let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] ?? [:]
    if let w = properties[kCGImagePropertyPixelWidth] as? NSNumber,
       let h = properties[kCGImagePropertyPixelHeight] as? NSNumber {
        _ = try checkedRasterSize(width: w.doubleValue, height: h.doubleValue)
    }
    guard let raw = CGImageSourceCreateImageAtIndex(source, index, nil) else {
        throw ToolError("image_decode_failed", "无法解码图片帧")
    }
    _ = try checkedRasterSize(width: Double(raw.width), height: Double(raw.height))
    let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
    guard (1...8).contains(orientation) else {
        throw ToolError("invalid_image_orientation", "图片 EXIF 方向无效")
    }
    let extra = try normalizedRotation(options.rotation)
    let (base, orientedWidth, orientedHeight) = exifTransform(orientation, width: Double(raw.width), height: Double(raw.height))
    let extraOrientation = [0: 1, 90: 6, 180: 3, 270: 8][extra]!
    let (turn, width, height) = exifTransform(extraOrientation, width: orientedWidth, height: orientedHeight)
    let (w, h) = try checkedRasterSize(width: width, height: height)
    let context = try bitmapContext(width: w, height: h)
    context.interpolationQuality = .none
    context.concatenate(base.concatenating(turn))
    context.draw(raw, in: CGRect(x: 0, y: 0, width: raw.width, height: raw.height))
    guard let image = context.makeImage() else { throw ToolError("image_orientation_failed", "图片方向归一化失败") }
    // EXIF is normalized before the user rotation; image coordinates describe
    // that normalized full image. rotation therefore reports the extra rotation.
    return try croppedRaster(image, width: width, height: height,
                             unit: "px", rotation: extra, sourceOrientation: orientation, options: options)
}

func extractPDFText(_ page: PDFPage, index: Int, options: Options) throws -> PageResult {
    let geometry = try pdfGeometry(page, options: options)
    let region = try normalizedRegion(options, width: geometry.width, height: geometry.height)
    let transform = geometry.drawingTransform(width: geometry.width, height: geometry.height)
    // A MediaBox selection keeps crop/user rotation independent of PDFKit's
    // displayed page bounds. Selection bounds are in unrotated PDF coordinates.
    let selection = page.selection(for: geometry.reference.getBoxRect(.mediaBox))
    var lines: [OCRLine] = []
    for (sourceIndex, line) in (selection?.selectionsByLine() ?? []).enumerated() {
        guard let rawText = line.string else { continue }
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { continue }
        let pdfBounds = line.bounds(for: page)
        guard !pdfBounds.isNull, pdfBounds.width > 0, pdfBounds.height > 0 else { continue }
        let mapped = pdfBounds.applying(transform)
        let bounds = CGRect(x: mapped.minX, y: geometry.height - mapped.maxY,
                            width: mapped.width, height: mapped.height)
        // A partial line cannot safely be returned with its entire text. Keep
        // only fully selected lines; this avoids attributing outside-ROI text
        // to a clipped bbox. OCR mode is available for partial-line crops.
        let tolerance = 0.01
        let selectionBounds = region.insetBy(dx: -tolerance, dy: -tolerance)
        guard selectionBounds.contains(bounds) else { continue }
        lines.append(OCRLine(bbox: [bounds.minX, bounds.minY, bounds.maxX, bounds.maxY],
                             text: text, sourceIndex: sourceIndex))
    }
    var result = PageResult(page: index)
    result.source = "text"
    result.width = geometry.width
    result.height = geometry.height
    result.unit = "pt"
    result.rotation = geometry.rotation
    result.pageBox = options.pageBox.rawValue
    result.region = options.region
    result.engine = "PDFKit"
    result.lines = sortReadingOrder(lines, order: options.effectiveReadingOrder)
    if options.region != nil || options.pageBox == .crop {
        result.warnings.append("text 模式仅返回完全落在页面框和 region 内的文本行；跨边界行请用 ocr 模式处理。")
    }
    return result
}
