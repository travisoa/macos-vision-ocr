import Foundation
import PDFKit
import ImageIO

// Conservative diagnosis: technical identifiers and uncommon languages must
// not be rejected merely because they lack common Chinese characters.
func textLayerIssue(_ text: String) -> String? {
    let scalars = text.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }
    guard !scalars.isEmpty else { return nil }
    if text.range(of: #"/G\d+(?:\s*/G\d+)+"#, options: .regularExpression) != nil {
        return "文本层包含连续 CID 字形编号"
    }
    let replacements = scalars.filter { $0.value == 0xFFFD }.count
    if replacements > 0 && Double(replacements) / Double(scalars.count) > 0.05 {
        return "文本层含较多 Unicode 替代字符"
    }
    let suspicious = scalars.filter {
        $0.value == 0xFFFD || (0xE000...0xF8FF).contains($0.value) ||
        (0xF0000...0xFFFFD).contains($0.value) || (0x100000...0x10FFFD).contains($0.value) ||
        CharacterSet.controlCharacters.contains($0)
    }.count
    if suspicious >= 2 && Double(suspicious) / Double(scalars.count) > 0.05 {
        return "文本层含较多替代字符、控制字符或私用码位"
    }
    return nil
}

final class Pipeline {
    let options: Options
    let writer: OutputWriter
    private var languageValidation: Result<Void, Error>?
    private(set) var failed = false

    init(options: Options, writer: OutputWriter) { self.options = options; self.writer = writer }

    private func checkLanguages() throws {
        if let cached = languageValidation { return try cached.get() }
        let result = Result { try validateLanguages(options: options) }
        languageValidation = result
        return try result.get()
    }

    func run() async throws -> Bool {
        for file in options.files {
            try writer.beginDocument(file: file)
            // Processing errors are data; writer failures propagate directly.
            var fileError: ToolError?
            let url = URL(fileURLWithPath: file)
            do {
                let attributes = try FileManager.default.attributesOfItem(atPath: url.resolvingSymlinksInPath().path)
                guard attributes[.type] as? FileAttributeType == .typeRegular else {
                    throw ToolError("invalid_input", "输入不是普通文件：\(file)")
                }
            } catch { fileError = toolError(error, code: "input_unreadable") }
            if fileError == nil {
                if url.pathExtension.lowercased() == "pdf" {
                    if let document = PDFDocument(url: url) {
                        if document.isLocked {
                            fileError = ToolError("pdf_locked", "PDF 已加密且需要密码：\(file)")
                        } else if document.pageCount == 0 {
                            fileError = ToolError("empty_document", "PDF 不含页面：\(file)")
                        } else {
                            let selection = Result { try selectedPages(ranges: options.pageRanges, count: document.pageCount) }
                            switch selection {
                            case .failure(let error): fileError = toolError(error)
                            case .success(let pages):
                                for index in pages {
                                    if options.progress { stderrPrint("\(file)：第 \(index + 1)/\(document.pageCount) 页") }
                                    let result: PageResult
                                    do {
                                        guard let page = document.page(at: index) else { throw ToolError("page_unreadable", "无法读取 PDF 第 \(index + 1) 页") }
                                        result = try await processPDFPage(page, index: index)
                                    } catch { result = failedPage(index: index, error: error) }
                                    try emit(result, file: file)
                                }
                            }
                        }
                    } else { fileError = ToolError("invalid_pdf", "无法读取 PDF：\(file)") }
                } else if options.mode == .text {
                    fileError = ToolError("invalid_input", "--mode text 只适用于 PDF：\(file)")
                } else if let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0 {
                    let selection = Result { try selectedPages(ranges: options.pageRanges, count: CGImageSourceGetCount(source)) }
                    switch selection {
                    case .failure(let error): fileError = toolError(error)
                    case .success(let pages):
                        for index in pages {
                            if options.progress { stderrPrint("\(file)：第 \(index + 1)/\(CGImageSourceGetCount(source)) 帧") }
                            let result: PageResult
                            do {
                                let raster = try autoreleasepool { try loadImageFrame(source, index: index, options: options) }
                                try checkLanguages()
                                result = try await recognizeRaster(raster, index: index, options: options)
                            } catch { result = failedPage(index: index, error: error) }
                            try emit(result, file: file)
                        }
                    }
                } else { fileError = ToolError("invalid_image", "无法读取图片：\(file)") }
            }
            if let error = fileError {
                failed = true
                stderrPrint("\(file)：\(error.message)")
            }
            try writer.endDocument(error: fileError)
        }
        try writer.finish()
        return !failed
    }

    private func processPDFPage(_ page: PDFPage, index: Int) async throws -> PageResult {
        if options.mode != .ocr && options.region == nil {
            var result = try autoreleasepool { try extractPDFText(page, index: index, options: options) }
            let text = result.lines.map(\.text).joined(separator: "\n")
            if let issue = textLayerIssue(text) {
                throw ToolError("text_layer_unusable", "\(issue)；请检查 CID/ToUnicode 码表并按既有方法重建；确需直接 OCR 时显式使用 --mode ocr")
            }
            if options.mode == .text || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result.lines = sortReadingOrder(result.lines, order: options.effectiveReadingOrder)
                result.status = result.lines.isEmpty ? "empty" : "ok"
                if result.lines.isEmpty { result.warnings.append("no_extractable_text_layer") }
                return result
            }
        }
        let raster = try autoreleasepool { try renderPDFPage(page, options: options) }
        try checkLanguages()
        var result = try await recognizeRaster(raster, index: index, options: options)
        if options.mode == .auto && options.region != nil { result.warnings.append("region_requires_ocr") }
        return result
    }

    private func failedPage(index: Int, error: Error) -> PageResult {
        var result = PageResult(page: index)
        result.source = options.mode.rawValue
        result.status = "error"
        result.error = toolError(error)
        return result
    }

    private func emit(_ result: PageResult, file: String) throws {
        if result.status == "error" {
            failed = true
            stderrPrint("\(file) 第 \(result.page + 1) 页：\(result.error?.message ?? "处理失败")")
        }
        try writer.writePage(result)
    }
}
