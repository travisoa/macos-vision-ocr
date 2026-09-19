import Foundation

struct UnitTestFailure: Error, CustomStringConvertible {
    let description: String
}

func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw UnitTestFailure(description: message) }
}

@main
struct TestRunner {
    static func main() {
        do {
            try runGeometryTests()
            try runOutputTests()
            try runTextLayerTests()
            print("Unit tests passed")
        } catch {
            fputs("Unit test failure: \(error)\n", stderr)
            exit(1)
        }
    }
}
