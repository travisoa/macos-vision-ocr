import XCTest
@testable import OCR
import Foundation

final class TextLayerTests: XCTestCase {
    func testTextLayer() throws {
        try expect(textLayerIssue("GB/T 7258—2020 质量 ±5% 1234 kg") == nil, "technical text must not be rejected")
        try expect(textLayerIssue("日本語 한국어 Français Ω Δ") == nil, "uncommon languages must not be rejected")
        try expect(textLayerIssue(" ") == nil, "empty layer is not corrupt")
        try expect(textLayerIssue("/G21/G22") != nil, "CID glyph codes must be diagnosed")
        try expect(textLayerIssue("/G21 /G22 /G23") != nil, "spaced CID glyph codes must be diagnosed")
        try expect(textLayerIssue("\u{FFFD}\u{FFFD}abc") != nil, "replacement characters must be diagnosed")
        try expect(textLayerIssue("\u{FFFD}") != nil, "single replacement-only text must not pass as usable text")
        try expect(textLayerIssue("\u{E010}\u{E011}abc") != nil, "private-use text must be diagnosed")
    }
}
