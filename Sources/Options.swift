import Foundation

func printHelp() {
    print("""
    ocr — 基于 macOS Vision 的离线图片与 PDF 文本工具

    用法: ocr [选项] <文件> [<文件> ...]

    识别:
      -l, --langs <码>       逗号分隔语言 (默认 zh-Hans,en-US)
      -f, --fast             快速模式 (默认精确模式)
      --no-correction        关闭语言纠错，适合标准、术语与编号
      --custom-words <文件>  UTF-8 自定义词典，每行一词，需启用纠错
      --candidates <1..10>   每行最多保留的候选数量
      --mode ocr|text|auto   强制 OCR / PDF 文本层 / 自动 (默认 ocr)
      --dpi <正数>          PDF 渲染 DPI (默认 200)
      --pages <1,3-5>        选择原始页码，从 1 开始，排序并去重
      --rotate <角度>       顺时针额外旋转 0/90/180/270 度
      --region <x,y,w,h>    旋转后页面左上原点的 0..1 归一化区域
      --page-box media|crop PDF 页面边界 (默认 media)
      --reading-order vision|row|column
                            行排序 (文本默认 vision，其余默认 row)
      --tables              实验性表格结构识别 (macOS 26+，仅精确 OCR)

    输出:
      --format text|json|jsonl|csv|markdown
      --json / --jsonl       对应格式的快捷选项
      --page-marker         文本输出文件与原始页码分隔标记
      --progress            进度写入 stderr
      -o, --output <文件>   完成后原子替换输出文件 (默认 stdout)
      --list-langs           列出当前精确/快速模式支持的语言
      --version             显示版本
      -h, --help             显示帮助
      --                    后续参数均为输入文件名

    CSV/Markdown 隐含 --tables。JSON 页码从 0 开始，保留源页码。
    退出码: 0 成功；1 文件/识别/输出失败；2 参数错误。
    """)
}

func parseOptions(_ arguments: [String]) throws -> Options {
    var options = Options()
    var index = 0
    var explicitFormat: OutputFormat?

    func argumentError(_ message: String) -> ToolError { ToolError("invalid_argument", message) }
    func nextValue(_ flag: String) throws -> String {
        index += 1
        guard index < arguments.count, !arguments[index].hasPrefix("--") else {
            throw argumentError("\(flag) 需要参数")
        }
        return arguments[index]
    }
    func selectFormat(_ format: OutputFormat) throws {
        if let previous = explicitFormat, previous != format {
            throw argumentError("不能同时指定不同输出格式: \(previous.rawValue)、\(format.rawValue)")
        }
        explicitFormat = format
        options.format = format
    }

    while index < arguments.count {
        let argument = arguments[index]
        switch argument {
        case "--":
            options.files.append(contentsOf: arguments.dropFirst(index + 1))
            index = arguments.count
            continue
        case "-h", "--help": options.showHelp = true
        case "--version": options.showVersion = true
        case "--list-langs": options.listLanguages = true
        case "-l", "--langs":
            let value = try nextValue(argument)
            let languages = value.split(separator: ",", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard !languages.isEmpty, languages.allSatisfy({ !$0.isEmpty && !$0.hasPrefix("-") }) else {
                throw argumentError("--langs 需要非空语言码，例如 zh-Hans,en-US")
            }
            options.languages = languages
        case "-f", "--fast": options.accurate = false
        case "--no-correction": options.correction = false
        case "--dpi":
            guard let number = Double(try nextValue(argument)), number.isFinite, number > 0 else {
                throw argumentError("--dpi 必须是有限正数")
            }
            options.dpi = number
        case "--page-marker": options.pageMarker = true
        case "--json": try selectFormat(.json)
        case "--jsonl": try selectFormat(.jsonl)
        case "--format":
            guard let format = OutputFormat(rawValue: try nextValue(argument)) else {
                throw argumentError("--format 仅支持 text、json、jsonl、csv、markdown")
            }
            try selectFormat(format)
        case "--mode":
            guard let mode = RecognitionMode(rawValue: try nextValue(argument)) else {
                throw argumentError("--mode 仅支持 ocr、text、auto")
            }
            options.mode = mode
        case "--reading-order":
            guard let order = ReadingOrder(rawValue: try nextValue(argument)) else {
                throw argumentError("--reading-order 仅支持 vision、row、column")
            }
            options.readingOrder = order
        case "--pages":
            let value = try nextValue(argument)
            let pieces = value.split(separator: ",", omittingEmptySubsequences: false)
            var ranges: [PageRange] = []
            for piece in pieces {
                let endpoints = piece.trimmingCharacters(in: .whitespacesAndNewlines)
                    .split(separator: "-", omittingEmptySubsequences: false)
                guard (1...2).contains(endpoints.count), endpoints.allSatisfy({
                    !$0.isEmpty && $0.utf8.allSatisfy({ (48...57).contains($0) })
                }), let first = Int(endpoints[0]), let last = Int(endpoints.last!), first > 0, last >= first else {
                    throw argumentError("--pages 需要正整数页码或递增范围，例如 1,3-5")
                }
                ranges.append(PageRange(first: first, last: last))
            }
            options.pageRanges = ranges
        case "--progress": options.progress = true
        case "-o", "--output":
            let value = try nextValue(argument)
            guard !value.isEmpty, value != "-h", value != "-f", value != "-l", value != "-o" else {
                throw argumentError("\(argument) 需要输出文件路径")
            }
            options.outputPath = value
        case "--rotate":
            let value = try nextValue(argument)
            guard let rotation = Int(value), [0, 90, 180, 270].contains(rotation) else {
                throw argumentError("--rotate 仅支持 0、90、180、270")
            }
            options.rotation = rotation
        case "--region":
            let pieces = try nextValue(argument).split(separator: ",", omittingEmptySubsequences: false)
            let values = pieces.compactMap { Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            guard pieces.count == 4, values.count == 4, values.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 1 }),
                  values[2] > 0, values[3] > 0, values[0] + values[2] <= 1,
                  values[1] + values[3] <= 1 else {
                throw argumentError("--region 需要 x,y,w,h；均为 0..1，宽高为正且区域不超出页面")
            }
            options.region = values
        case "--page-box":
            guard let box = PageBox(rawValue: try nextValue(argument)) else {
                throw argumentError("--page-box 仅支持 media、crop")
            }
            options.pageBox = box
        case "--candidates":
            guard let count = Int(try nextValue(argument)), (1...10).contains(count) else {
                throw argumentError("--candidates 必须是 1..10 的整数")
            }
            options.candidates = count
        case "--custom-words":
            let value = try nextValue(argument)
            guard !value.isEmpty, !value.hasPrefix("-") else {
                throw argumentError("--custom-words 需要词典文件路径")
            }
            options.wordsFile = value
        case "--tables": options.tables = true
        default:
            guard !argument.hasPrefix("-") else { throw argumentError("未知选项: \(argument)") }
            guard !argument.isEmpty else { throw argumentError("输入文件路径不能为空") }
            options.files.append(argument)
        }
        index += 1
    }

    if options.format == .csv || options.format == .markdown { options.tables = true }
    if options.tables && options.mode != .ocr { throw argumentError("--tables / CSV / Markdown 仅支持 --mode ocr") }
    if options.tables && !options.accurate { throw argumentError("--tables / CSV / Markdown 不支持 --fast") }
    if options.mode == .text && options.region != nil { throw argumentError("--mode text 暂不支持 --region") }
    if options.wordsFile != nil && !options.correction { throw argumentError("--custom-words 不能与 --no-correction 同时使用") }
    if let path = options.wordsFile {
        let content: String
        do { content = try String(contentsOfFile: path, encoding: .utf8) }
        catch { throw argumentError("无法读取 UTF-8 自定义词典 \(path): \(error.localizedDescription)") }
        var seen = Set<String>()
        options.customWords = content.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        guard !options.customWords.isEmpty else { throw argumentError("自定义词典不能为空") }
    }
    if options.files.isEmpty && !options.showHelp && !options.showVersion && !options.listLanguages {
        throw argumentError("请提供至少一个输入文件；使用 --help 查看用法")
    }
    if options.files.contains("") { throw argumentError("输入文件路径不能为空") }
    return options
}

func selectedPages(ranges: [PageRange]?, count: Int) throws -> [Int] {
    guard count >= 0 else { throw ToolError("invalid_argument", "页数不能为负数") }
    guard let ranges = ranges else { return Array(0..<count) }
    // Validate before expanding, so even an enormous user-supplied range fails cheaply.
    for range in ranges {
        guard range.first > 0, range.last >= range.first, range.last <= count else {
            throw ToolError("invalid_argument", "选择页码 \(range.first)-\(range.last) 超出有效页码 1..\(count)")
        }
    }
    var merged: [PageRange] = []
    for range in ranges.sorted(by: { $0.first == $1.first ? $0.last < $1.last : $0.first < $1.first }) {
        if let previous = merged.last, range.first <= previous.last || (previous.last < Int.max && range.first == previous.last + 1) {
            merged[merged.count - 1] = PageRange(first: previous.first, last: max(previous.last, range.last))
        } else {
            merged.append(range)
        }
    }
    return merged.flatMap { Array(($0.first - 1)..<$0.last) }
}
