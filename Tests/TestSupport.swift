import Foundation

struct UnitTestFailure: Error, CustomStringConvertible {
    let description: String
}

// Keep the existing throwing assertions so each fixture stops at its first
// failure, while preserving the precise source location in XCTest's report.
func expect(_ condition: @autoclosure () -> Bool, _ message: String,
            file: StaticString = #filePath, line: UInt = #line) throws {
    guard condition() else { throw UnitTestFailure(description: "\(file):\(line): \(message)") }
}
