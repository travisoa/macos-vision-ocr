import Foundation
import Darwin

/// The writer retains one page at a time. Named output is committed only by finish().
final class OutputWriter {
    private let options: Options
    private let handle: FileHandle
    private let outputPath: String?
    private var temporaryPath: String?
    private var finished = false
    private var documentCount = 0
    private var currentFile: String?
    private var pageCount = 0
    private var failedPages = 0
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        return encoder
    }()

    init(options: Options) throws {
        self.options = options
        if let path = options.outputPath {
            let target = URL(fileURLWithPath: path).standardizedFileURL
            let parent = target.deletingLastPathComponent().resolvingSymlinksInPath()
            let resolved = parent.appendingPathComponent(target.lastPathComponent).path
            try Self.validateOutput(path: resolved, inputs: options.files + (options.wordsFile.map { [$0] } ?? []))
            let temporary = parent.appendingPathComponent(".\(target.lastPathComponent).ocr-\(UUID().uuidString).tmp").path
            let descriptor = Darwin.open(temporary, O_WRONLY | O_CREAT | O_EXCL, mode_t(0o600))
            guard descriptor >= 0 else { throw ToolError("output_failed", "无法创建临时输出文件: \(String(cString: strerror(errno)))") }
            handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            outputPath = resolved
            temporaryPath = temporary
        } else {
            handle = .standardOutput
            outputPath = nil
        }
        do {
            if options.format == .json { try writeRaw("[") }
            if options.format == .csv { try writeRaw("file,page,table,row,column,row_span,column_span,text\n") }
        } catch {
            abort()
            throw error
        }
    }

    deinit { abort() }

    private static func validateOutput(path: String, inputs: [String]) throws {
        var targetStat = stat()
        let exists = lstat(path, &targetStat) == 0
        if !exists && errno != ENOENT { throw ToolError("output_failed", "无法检查输出路径: \(path)") }
        if exists {
            guard targetStat.st_mode & S_IFMT != S_IFLNK else { throw ToolError("output_failed", "禁止覆盖输出符号链接: \(path)") }
            guard targetStat.st_mode & S_IFMT == S_IFREG else { throw ToolError("output_failed", "输出路径不是普通文件: \(path)") }
        }
        for input in inputs {
            let inputPath = URL(fileURLWithPath: input).standardizedFileURL.resolvingSymlinksInPath().path
            guard inputPath != path else { throw ToolError("output_failed", "输出路径不能与输入文件相同: \(input)") }
            var inputStat = stat()
            if exists && stat(inputPath, &inputStat) == 0 && inputStat.st_dev == targetStat.st_dev && inputStat.st_ino == targetStat.st_ino {
                throw ToolError("output_failed", "输出路径与输入文件是同一文件的硬链接: \(input)")
            }
        }
    }

    private func writeRaw(_ text: String) throws { try writeData(Data(text.utf8)) }

    private func writeData(_ data: Data) throws {
        guard !finished else { throw ToolError("output_failed", "输出已关闭") }
        do { try handle.write(contentsOf: data) }
        catch { throw ToolError("output_failed", "写入输出失败: \(error.localizedDescription)") }
    }

    private func encode<T: Encodable>(_ value: T) throws -> Data {
        do { return try encoder.encode(value) }
        catch { throw ToolError("output_failed", "JSON 序列化失败: \(error.localizedDescription)") }
    }

    private func jsonString(_ text: String) throws -> String { String(decoding: try encode(text), as: UTF8.self) }

    private func writeObject(_ object: [String: Any]) throws {
        let data: Data
        do { data = try JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes, .sortedKeys]) }
        catch { throw ToolError("output_failed", "JSON 序列化失败: \(error.localizedDescription)") }
        try writeData(data)
        try writeRaw("\n")
    }

    func beginDocument(file: String) throws {
        guard currentFile == nil else { throw ToolError("output_failed", "上一文件输出尚未结束") }
        currentFile = file
        pageCount = 0
        failedPages = 0
        switch options.format {
        case .json:
            if documentCount > 0 { try writeRaw(",") }
            try writeRaw("{\"schemaVersion\":\(schemaVersion),\"toolVersion\":\(try jsonString(toolVersion)),\"file\":\(try jsonString(file)),\"pages\":[")
        case .text:
            if options.files.count > 1 || options.pageMarker { try writeRaw("===== \(file) =====\n") }
        default: break
        }
        documentCount += 1
    }

    func writePage(_ page: PageResult) throws {
        guard let file = currentFile else { throw ToolError("output_failed", "尚未开始文件输出") }
        switch options.format {
        case .json:
            // Encode before emitting the separator to avoid an extra dangling comma.
            let data = try encode(page)
            if pageCount > 0 { try writeRaw(",") }
            try writeData(data)
        case .jsonl:
            let pageData = try encode(page)
            guard var object = try JSONSerialization.jsonObject(with: pageData) as? [String: Any] else {
                throw ToolError("output_failed", "页面无法编码为 JSON 对象")
            }
            object["type"] = "page"
            object["file"] = file
            object["schemaVersion"] = schemaVersion
            object["toolVersion"] = toolVersion
            try writeObject(object)
        case .text:
            if pageCount > 0 { try writeRaw("\n") }
            if options.pageMarker { try writeRaw("----- 第 \(page.page + 1) 页 -----\n") }
            try writeRaw(page.lines.map(\.text).joined(separator: "\n") + "\n")
        case .csv, .markdown:
            for (index, table) in (page.tables ?? []).enumerated() {
                try writeTable(table, file: file, page: page.page, index: index)
            }
        }
        pageCount += 1
        if page.status == "error" || page.error != nil { failedPages += 1 }
    }

    func endDocument(error: ToolError? = nil) throws {
        guard let file = currentFile else { throw ToolError("output_failed", "尚未开始文件输出") }
        let hasError = error != nil || failedPages > 0
        let status = hasError ? (pageCount > failedPages ? "partial" : "error") : "ok"
        switch options.format {
        case .json:
            try writeRaw("],\"status\":\(try jsonString(status)),\"pageCount\":\(pageCount),\"failedPages\":\(failedPages)")
            if let error { try writeRaw(",\"error\":"); try writeData(encode(error)) }
            try writeRaw("}")
        case .jsonl:
            if let error {
                try writeObject(["type": "file_error", "file": file, "schemaVersion": schemaVersion,
                                 "toolVersion": toolVersion, "status": "error",
                                 "error": ["code": error.code, "message": error.message]])
            }
            try writeObject(["type": "file_end", "file": file, "schemaVersion": schemaVersion,
                             "toolVersion": toolVersion, "status": status, "pageCount": pageCount,
                             "failedPages": failedPages])
        default: break
        }
        currentFile = nil
    }

    func finish() throws {
        guard !finished else { return }
        guard currentFile == nil else { throw ToolError("output_failed", "文件输出尚未结束") }
        if options.format == .json { try writeRaw("]\n") }
        if let outputPath, let temporaryPath {
            do { try handle.synchronize(); try handle.close() }
            catch { throw ToolError("output_failed", "完成输出失败: \(error.localizedDescription)") }
            try Self.validateOutput(path: outputPath, inputs: options.files + (options.wordsFile.map { [$0] } ?? []))
            guard Darwin.rename(temporaryPath, outputPath) == 0 else {
                throw ToolError("output_failed", "无法提交输出文件: \(String(cString: strerror(errno)))")
            }
            self.temporaryPath = nil
        }
        finished = true
    }

    func abort() {
        guard !finished else { return }
        if let temporaryPath {
            try? handle.close()
            try? FileManager.default.removeItem(atPath: temporaryPath)
            self.temporaryPath = nil
        }
        finished = true
    }

    private func writeTable(_ table: OCRTable, file: String, page: Int, index: Int) throws {
        guard table.rows > 0, table.columns > 0, table.rows <= 1_000_000 / table.columns else {
            throw ToolError("output_failed", "表格网格大小无效或超过安全上限")
        }
        var anchors: [Int: TableCell] = [:]
        for cell in table.cells {
            guard cell.row >= 0, cell.column >= 0, cell.row < table.rows, cell.column < table.columns,
                  cell.rowSpan > 0, cell.columnSpan > 0,
                  cell.rowSpan <= table.rows - cell.row, cell.columnSpan <= table.columns - cell.column else {
                throw ToolError("output_failed", "表格单元格范围无效")
            }
            anchors[cell.row * table.columns + cell.column] = cell
        }
        if options.format == .csv {
            for row in 0..<table.rows {
                for column in 0..<table.columns {
                    let cell = anchors[row * table.columns + column]
                    let fields = [file, String(page), String(index), String(row), String(column),
                                  String(cell?.rowSpan ?? 1), String(cell?.columnSpan ?? 1), cell?.text ?? ""]
                    try writeRaw(fields.map(csvField).joined(separator: ",") + "\n")
                }
            }
        } else {
            try writeRaw("### \(markdownCell(file)) · page \(page) · table \(index)\n\n")
            try writeRaw("| " + (0..<table.columns).map { "column \($0)" }.joined(separator: " | ") + " |\n")
            try writeRaw("| " + Array(repeating: "---", count: table.columns).joined(separator: " | ") + " |\n")
            for row in 0..<table.rows {
                let values = (0..<table.columns).map { markdownCell(anchors[row * table.columns + $0]?.text ?? "") }
                try writeRaw("| " + values.joined(separator: " | ") + " |\n")
            }
            try writeRaw("\n")
        }
    }

    private func csvField(_ value: String) -> String {
        if value.contains(",") || value.contains("\"") || value.contains("\n") || value.contains("\r") {
            return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return value
    }

    private func markdownCell(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "|", with: "\\|")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\n", with: "<br>")
    }
}
