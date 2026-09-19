import Foundation
import Vision
import CoreGraphics

func supportedLanguages(options: Options) throws -> [String] {
    if options.tables {
        if #available(macOS 26.0, *) {
            return RecognizeDocumentsRequest().supportedRecognitionLanguages.map { $0.minimalIdentifier }
        }
        throw ToolError("unsupported_os", "表格结构识别需要 macOS 26 或更新版本")
    }
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = options.accurate ? .accurate : .fast
    return try request.supportedRecognitionLanguages()
}

func validateLanguages(options: Options) throws {
    let supported = try supportedLanguages(options: options)
    let normalized = Set(supported.map { $0.lowercased().replacingOccurrences(of: "_", with: "-") })
    let bad = options.languages.filter {
        let name = $0.lowercased().replacingOccurrences(of: "_", with: "-")
        if normalized.contains(name) { return false }
        if options.tables, #available(macOS 13.0, *) {
            return !normalized.contains(Locale.Language(identifier: $0).minimalIdentifier.lowercased())
        }
        return true
    }
    if !bad.isEmpty {
        throw ToolError("unsupported_language", "当前识别模式不支持语言：\(bad.joined(separator: ", "))；用相同选项加 --list-langs 查询")
    }
}

func pageBounds(_ normalized: CGRect, raster: RasterPage) -> [Double] {
    let width = Double(raster.image.width) / raster.scaleX
    let height = Double(raster.image.height) / raster.scaleY
    return [raster.offsetX + normalized.minX * width,
            raster.offsetY + (1 - normalized.maxY) * height,
            raster.offsetX + normalized.maxX * width,
            raster.offsetY + (1 - normalized.minY) * height]
}

func baseResult(raster: RasterPage, index: Int, options: Options) -> PageResult {
    var result = PageResult(page: index)
    result.width = raster.width
    result.height = raster.height
    result.unit = raster.unit
    result.rotation = raster.rotation
    result.sourceOrientation = raster.sourceOrientation
    result.region = options.region
    if raster.unit == "pt" {
        result.pageBox = options.pageBox.rawValue
        result.dpi = options.dpi
    }
    return result
}

func recognizeRaster(_ raster: RasterPage, index: Int, options: Options) async throws -> PageResult {
    if options.tables {
        if #available(macOS 26.0, *) {
            return try await recognizeDocument(raster, index: index, options: options)
        }
        throw ToolError("unsupported_os", "表格结构识别需要 macOS 26 或更新版本")
    }
    return try autoreleasepool {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = options.accurate ? .accurate : .fast
        request.recognitionLanguages = options.languages
        request.usesLanguageCorrection = options.correction
        request.customWords = options.customWords
        do {
            try VNImageRequestHandler(cgImage: raster.image, options: [:]).perform([request])
        } catch { throw recognitionError(error) }
        var result = baseResult(raster: raster, index: index, options: options)
        result.engine = "Vision.VNRecognizeTextRequest"
        result.engineRevision = request.revision
        result.lines = (request.results ?? []).enumerated().compactMap { index, observation in
            let candidates = observation.topCandidates(options.candidates)
            guard let first = candidates.first else { return nil }
            return OCRLine(bbox: pageBounds(observation.boundingBox, raster: raster),
                           text: first.string, confidence: first.confidence,
                           candidates: options.candidates > 1 ? candidates.map {
                               TextCandidate(text: $0.string, confidence: $0.confidence)
                           } : nil, sourceIndex: index)
        }
        result.lines = sortReadingOrder(result.lines, order: options.effectiveReadingOrder)
        result.status = result.lines.isEmpty ? "empty" : "ok"
        return result
    }
}

func recognitionError(_ error: Error) -> ToolError {
    let detail = String(describing: error)
    let hint = detail.contains("nilError") || detail.contains("e5rtError")
        ? "；可能是当前 sandbox 限制 ANE/XPC/IOKit，按当前执行环境申请所需权限后重试" : ""
    return ToolError("recognition_failed", "Vision 识别失败：\(detail)\(hint)")
}

@available(macOS 26.0, *)
private func recognizeDocument(_ raster: RasterPage, index: Int, options: Options) async throws -> PageResult {
    var request = RecognizeDocumentsRequest()
    request.textRecognitionOptions.recognitionLanguages = options.languages.map { Locale.Language(identifier: $0) }
    request.textRecognitionOptions.automaticallyDetectLanguage = false
    request.textRecognitionOptions.useLanguageCorrection = options.correction
    request.textRecognitionOptions.customWords = options.customWords
    request.textRecognitionOptions.maximumCandidateCount = options.candidates
    request.barcodeDetectionOptions.enabled = false
    let observations: [DocumentObservation]
    do { observations = try await request.perform(on: raster.image) }
    catch { throw recognitionError(error) }

    var result = baseResult(raster: raster, index: index, options: options)
    result.engine = "Vision.RecognizeDocumentsRequest"
    result.engineRevision = 1
    result.tables = []
    for observation in observations {
        for line in observation.document.text.lines {
            let candidates = line.topCandidates(options.candidates)
            guard let first = candidates.first else { continue }
            result.lines.append(OCRLine(bbox: pageBounds(line.boundingBox.cgRect, raster: raster),
                text: first.string, confidence: first.confidence,
                candidates: options.candidates > 1 ? candidates.map {
                    TextCandidate(text: $0.string, confidence: $0.confidence)
                } : nil, sourceIndex: result.lines.count))
        }
        for table in observation.document.tables {
            var seen: Set<String> = []
            var cells: [TableCell] = []
            for row in table.rows {
                for cell in row {
                    let key = "\(cell.rowRange.lowerBound):\(cell.columnRange.lowerBound):\(cell.rowRange.upperBound):\(cell.columnRange.upperBound)"
                    guard seen.insert(key).inserted else { continue }
                    cells.append(TableCell(row: cell.rowRange.lowerBound, column: cell.columnRange.lowerBound,
                        rowSpan: cell.rowRange.count, columnSpan: cell.columnRange.count,
                        bbox: pageBounds(cell.content.boundingRegion.boundingBox.cgRect, raster: raster),
                        text: cell.content.text.transcript))
                }
            }
            cells.sort { $0.row == $1.row ? $0.column < $1.column : $0.row < $1.row }
            result.tables?.append(OCRTable(bbox: pageBounds(table.boundingRegion.boundingBox.cgRect, raster: raster),
                rows: table.rows.count, columns: table.columns.count, cells: cells))
        }
    }
    result.lines = sortReadingOrder(result.lines, order: options.effectiveReadingOrder)
    result.status = result.lines.isEmpty && (result.tables?.isEmpty ?? true) ? "empty" : "ok"
    if result.tables?.isEmpty == true { result.warnings.append("no_tables_detected") }
    return result
}
