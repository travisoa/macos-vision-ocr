import XCTest
@testable import OCR

final class ParserTests: XCTestCase {
    func testExecutableModuleExposesParserWithoutRunningCLI() throws {
        let options = try parseOptions(["--mode", "text", "--jsonl", "--pages", "3,1,3", "fixture.pdf"])
        XCTAssertEqual(options.mode.rawValue, "text")
        XCTAssertEqual(options.format.rawValue, "jsonl")
        XCTAssertEqual(options.files, ["fixture.pdf"])
        XCTAssertEqual(try selectedPages(ranges: options.pageRanges, count: 3), [0, 2])
    }
}
