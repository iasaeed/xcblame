import XCTest
@testable import XcblameKit

/// Phase 1 stubs throw `XcblameError.notImplemented`; the lane that fills a body replaces its stub test.
func assertNotImplemented<T>(_ expression: @autoclosure () throws -> T, _ fragment: String,
                             file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertThrowsError(try expression(), file: file, line: line) { error in
        guard case let XcblameError.notImplemented(what) = error else {
            return XCTFail("expected notImplemented, got \(error)", file: file, line: line)
        }
        XCTAssertTrue(what.contains(fragment), what, file: file, line: line)
    }
}

/// A report of the synthetic model, for the stub tests.
func syntheticReport() throws -> ReportDocument {
    try ReportPipeline.run(SyntheticModel.make(), options: .init(generatedAt: Date(timeIntervalSince1970: 0))).document
}
