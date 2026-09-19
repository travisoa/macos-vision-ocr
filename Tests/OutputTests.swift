import Foundation

func runOutputTests() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("ocr-writer-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let table = OCRTable(bbox: [0, 0, 100, 100], rows: 2, columns: 2, cells: [
        TableCell(row: 0, column: 0, rowSpan: 1, columnSpan: 2, bbox: [0, 0, 100, 50], text: "中,\"quoted\"\nline"),
        TableCell(row: 1, column: 0, rowSpan: 1, columnSpan: 1, bbox: [0, 50, 50, 100], text: "A|B & <x>"),
        TableCell(row: 1, column: 1, rowSpan: 1, columnSpan: 1, bbox: [50, 50, 100, 100], text: "尾"),
    ])
    var page = PageResult(page: 4)
    page.tables = [table]

    func output(_ name: String, format: OutputFormat, pages: [PageResult]) throws -> String {
        var options = Options()
        options.format = format
        options.outputPath = root.appendingPathComponent(name).path
        let writer = try OutputWriter(options: options)
        try writer.beginDocument(file: "sample,文档.pdf")
        for page in pages { try writer.writePage(page) }
        try writer.endDocument()
        try writer.finish()
        return try String(contentsOfFile: options.outputPath!, encoding: .utf8)
    }

    let csv = try output("table.csv", format: .csv, pages: [page])
    try expect(csv.hasPrefix("file,page,table,row,column,row_span,column_span,text\n"), "CSV header is missing")
    try expect(csv.contains("\"sample,文档.pdf\",4,0,0,0,1,2,\"中,\"\"quoted\"\"\nline\"\n"), "CSV must quote commas, quotes, and embedded newlines without losing Unicode")
    try expect(csv.contains("\"sample,文档.pdf\",4,0,0,1,1,1,\n"), "Merged cell coverage must remain empty in CSV")
    let markdown = try output("table.md", format: .markdown, pages: [page])
    try expect(markdown.contains("中,\"quoted\"<br>line"), "Markdown must preserve multiline table content")
    try expect(markdown.contains("A\\|B &amp; &lt;x&gt;"), "Markdown must escape pipes and HTML characters")
    try expect(markdown.contains("| 尾") || markdown.contains(" | 尾 |"), "Markdown must preserve Unicode")

    var empty = PageResult(page: 7)
    empty.status = "empty"
    let emptyJSON = try output("empty.json", format: .json, pages: [empty])
    let emptyDocuments = try JSONSerialization.jsonObject(with: Data(emptyJSON.utf8)) as! [[String: Any]]
    try expect(emptyDocuments[0]["status"] as? String == "ok", "A page with no text is successful, not an error")
    try expect(emptyDocuments[0]["failedPages"] as? Int == 0, "Empty pages must not count as failures")

    var failed = PageResult(page: 9)
    failed.status = "error"
    failed.error = ToolError("fixture_error", "known page failure")
    let partialJSON = try output("partial.json", format: .json, pages: [empty, failed])
    let partialDocuments = try JSONSerialization.jsonObject(with: Data(partialJSON.utf8)) as! [[String: Any]]
    try expect(partialDocuments[0]["status"] as? String == "partial", "Page-level errors must produce partial document status")
    let partialPages = partialDocuments[0]["pages"] as! [[String: Any]]
    try expect(partialPages.map { $0["page"] as! Int } == [7, 9], "Writer must retain source page numbers across errors")

    var options = Options()
    options.format = .json
    let protected = root.appendingPathComponent("existing.json")
    options.outputPath = protected.path
    try "previous successful result".write(to: protected, atomically: true, encoding: .utf8)
    let writer = try OutputWriter(options: options)
    try writer.beginDocument(file: "sample.pdf")
    try writer.writePage(page)
    let unfinishedContent = try String(contentsOf: protected, encoding: .utf8)
    try expect(unfinishedContent == "previous successful result", "Unfinished output must not replace an existing result")
    writer.abort()
    let abortedContent = try String(contentsOf: protected, encoding: .utf8)
    try expect(abortedContent == "previous successful result", "Aborting must preserve existing output")
    let remaining = try FileManager.default.contentsOfDirectory(atPath: root.path)
    try expect(!remaining.contains(where: { $0.hasSuffix(".tmp") }), "Writer must remove temporary files after abort")
}
