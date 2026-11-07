import Foundation
import XCTest
@testable import XcblameKit

/// Perf gate: the biggest fixture (v13 clean build, 13.4 MB inflated) decodes in under 1 s in release builds.
/// Run with `swift test -c release -Xswiftc -enable-testing --filter SLFPerformanceTests`.
final class SLFPerformanceTests: XCTestCase {
    func testBiggestFixtureDecodesUnderOneSecond() throws {
        let url = try XCTUnwrap(SLFFixtures.allLogs.max { size($0) < size($1) })
        var best = Double.infinity
        var sections = 0
        for _ in 0..<5 {
            let start = DispatchTime.now().uptimeNanoseconds
            let log = try SLFReader.read(url: url)
            let model = BuildModelBuilder.build(log, reader: .slf)
            best = min(best, Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9)
            sections = RawCounts(log).sections
            XCTAssertGreaterThan(model.tasks.count, 500)
        }
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        print(String(format: "perf %@: read+build best of 5 = %.3f s, sections=%d, maxRSS=%.1f MB",
                     url.lastPathComponent, best, sections, Double(usage.ru_maxrss) / 1_048_576))
        #if !DEBUG
        XCTAssertLessThan(best, 1.0)
        #endif
    }

    private func size(_ url: URL) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int) ?? 0
    }
}
