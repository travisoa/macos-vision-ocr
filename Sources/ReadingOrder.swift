import Foundation

private struct IndexedLine {
    let line: OCRLine
    let index: Int
    var x0: Double { line.bbox[0] }
    var y0: Double { line.bbox[1] }
    var x1: Double { line.bbox[2] }
    var y1: Double { line.bbox[3] }
    var centerY: Double { (y0 + y1) / 2 }
    var height: Double { max(1, y1 - y0) }
}

private func verticalOrder(_ a: IndexedLine, _ b: IndexedLine) -> Bool {
    if a.y0 != b.y0 { return a.y0 < b.y0 }
    if a.x0 != b.x0 { return a.x0 < b.x0 }
    if a.line.sourceIndex != b.line.sourceIndex { return a.line.sourceIndex < b.line.sourceIndex }
    return a.index < b.index
}

private func horizontalOrder(_ a: IndexedLine, _ b: IndexedLine) -> Bool {
    if a.x0 != b.x0 { return a.x0 < b.x0 }
    return verticalOrder(a, b)
}

private struct TextRow {
    let anchor: IndexedLine
    var lines: [IndexedLine]
}

// Clustering is separate from sorting: proximity is not transitive and must
// never be used directly as a sorted(by:) comparison relation.
private func textRows(_ lines: [IndexedLine]) -> [TextRow] {
    var rows: [TextRow] = []
    for line in lines.sorted(by: verticalOrder) {
        var closest: Int? = nil
        var distance = Double.infinity
        for index in rows.indices {
            let anchor = rows[index].anchor
            let overlap = min(line.y1, anchor.y1) - max(line.y0, anchor.y0)
            let dy = abs(line.centerY - anchor.centerY)
            let minimumHeight = min(line.height, anchor.height)
            if (overlap >= minimumHeight * 0.5 || dy <= minimumHeight * 0.35), dy < distance {
                closest = index
                distance = dy
            }
        }
        if let index = closest { rows[index].lines.append(line) }
        else { rows.append(TextRow(anchor: line, lines: [line])) }
    }
    for index in rows.indices { rows[index].lines.sort(by: horizontalOrder) }
    return rows
}

private func rowOrder(_ lines: [IndexedLine]) -> [IndexedLine] {
    textRows(lines).flatMap { $0.lines }
}

private func columnGutter(_ lines: [IndexedLine]) -> Double? {
    guard lines.count >= 4 else { return nil }
    let minX = lines.map(\.x0).min()!, maxX = lines.map(\.x1).max()!
    let minimumGap = max(12, (maxX - minX) * 0.04)
    let edges = Array(Set(lines.flatMap { [$0.x0, $0.x1] })).sorted()
    guard edges.count >= 2 else { return nil }
    var best: (score: Double, middle: Double)? = nil
    for index in 0..<(edges.count - 1) {
        let gap = edges[index + 1] - edges[index]
        guard gap >= minimumGap else { continue }
        let middle = (edges[index] + edges[index + 1]) / 2
        let left = lines.filter { $0.x1 <= middle }
        let right = lines.filter { $0.x0 >= middle }
        guard left.count >= 2, right.count >= 2,
              Double(left.count + right.count) >= Double(lines.count) * 0.7 else { continue }
        let leftTop = left.map(\.y0).min()!, leftBottom = left.map(\.y1).max()!
        let rightTop = right.map(\.y0).min()!, rightBottom = right.map(\.y1).max()!
        let overlap = min(leftBottom, rightBottom) - max(leftTop, rightTop)
        guard overlap > 0,
              overlap >= min(leftBottom - leftTop, rightBottom - rightTop) * 0.4 else { continue }
        let score = Double(min(left.count, right.count)) * gap
        if best == nil || score > best!.score { best = (score, middle) }
    }
    return best?.middle
}

private func columnOrder(_ lines: [IndexedLine], depth: Int = 0) -> [IndexedLine] {
    guard depth < 8, let split = columnGutter(lines) else { return rowOrder(lines) }
    let spanning = lines.filter { $0.x0 < split && $0.x1 > split }
    var body = lines.filter { !($0.x0 < split && $0.x1 > split) }
    func columns(_ band: [IndexedLine]) -> [IndexedLine] {
        let left = band.filter { $0.x1 <= split }
        let right = band.filter { $0.x0 >= split }
        return columnOrder(left, depth: depth + 1) + columnOrder(right, depth: depth + 1)
    }
    if spanning.isEmpty { return columns(body) }
    var result: [IndexedLine] = []
    // Full-width headings separate vertical bands; within each band read the
    // left column before the right. Ambiguous layouts fall back to row order.
    for row in textRows(spanning) {
        let boundary = row.anchor.centerY
        let before = body.filter { $0.centerY < boundary }
        body.removeAll { $0.centerY < boundary }
        result += columns(before)
        result += row.lines
    }
    result += columns(body)
    return result
}

func sortReadingOrder(_ lines: [OCRLine], order: ReadingOrder) -> [OCRLine] {
    guard order != .vision else { return lines }
    // Malformed caller-supplied geometry has no reliable geometric order.
    guard lines.allSatisfy({ $0.bbox.count == 4 && $0.bbox.allSatisfy(\.isFinite) }) else { return lines }
    let indexed = lines.enumerated().map { IndexedLine(line: $0.element, index: $0.offset) }
    return (order == .column ? columnOrder(indexed) : rowOrder(indexed)).map(\.line)
}
