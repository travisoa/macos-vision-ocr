import Foundation
import CoreGraphics

let toolVersion = "0.2.0"
let schemaVersion = 2

struct ToolError: Error, LocalizedError, Codable {
    let code: String
    let message: String
    var errorDescription: String? { message }
    init(_ code: String, _ message: String) { self.code = code; self.message = message }
}

enum OutputFormat: String { case text, json, jsonl, csv, markdown }
enum RecognitionMode: String { case ocr, text, auto }
enum ReadingOrder: String { case vision, row, column }
enum PageBox: String { case media, crop }

struct PageRange {
    let first: Int
    let last: Int
}

struct Options {
    var files: [String] = []
    var languages = ["zh-Hans", "en-US"]
    var accurate = true
    var correction = true
    var dpi = 200.0
    var pageMarker = false
    var format: OutputFormat = .text
    var mode: RecognitionMode = .ocr
    var readingOrder: ReadingOrder? = nil
    var pageRanges: [PageRange]? = nil
    var progress = false
    var outputPath: String? = nil
    var rotation = 0
    // Normalized [x, y, width, height], top-left in the oriented full page.
    var region: [Double]? = nil
    var pageBox: PageBox = .media
    var candidates = 1
    var wordsFile: String? = nil
    var customWords: [String] = []
    var tables = false
    var showHelp = false
    var showVersion = false
    var listLanguages = false
    var effectiveReadingOrder: ReadingOrder { readingOrder ?? (format == .text ? .vision : .row) }
}

struct TextCandidate: Codable {
    var text: String
    var confidence: Float
}

struct OCRLine: Codable {
    var bbox: [Double]
    var text: String
    var confidence: Float? = nil
    var candidates: [TextCandidate]? = nil
    var sourceIndex: Int = 0
}

struct TableCell: Codable {
    var row: Int
    var column: Int
    var rowSpan: Int
    var columnSpan: Int
    var bbox: [Double]
    var text: String
}

struct OCRTable: Codable {
    var bbox: [Double]
    var rows: Int
    var columns: Int
    var cells: [TableCell]
}

struct PageResult: Codable {
    // Zero-based source page/frame index, retained even when other pages fail.
    var page: Int
    var status: String = "ok"
    var source: String = "ocr"
    var width: Double? = nil
    var height: Double? = nil
    var unit: String? = nil
    var rotation: Int? = nil
    var sourceOrientation: Int? = nil
    var pageBox: String? = nil
    var dpi: Double? = nil
    var coordinateSpace: String = "oriented-page-top-left"
    var region: [Double]? = nil
    var engine: String? = nil
    var engineRevision: Int? = nil
    var lines: [OCRLine] = []
    var tables: [OCRTable]? = nil
    var warnings: [String] = []
    var error: ToolError? = nil
}

// Image pixels map directly to the oriented full-page coordinates. Crops keep
// the full-page coordinate origin via offsetX/Y; width/height are before crop.
struct RasterPage {
    let image: CGImage
    let width: Double
    let height: Double
    let unit: String
    let rotation: Int
    let scaleX: Double
    let scaleY: Double
    let offsetX: Double
    let offsetY: Double
    var sourceOrientation: Int? = nil
}

func stderrPrint(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

func toolError(_ error: Error, code: String = "processing_failed") -> ToolError {
    if let known = error as? ToolError { return known }
    return ToolError(code, error.localizedDescription)
}
