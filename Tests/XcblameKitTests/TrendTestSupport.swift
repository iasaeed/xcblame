import Foundation
import XCTest
@testable import XcblameKit

/// Synthetic history for the trend tests: real entries written by `History.save`, with the members trend reads set
/// by hand (wall, busy, kind, scheme, Xcode, git, machine, time).
enum TrendFixture {
    /// A week ago: recent enough that `History.save`'s own 90-day prune never takes the entries.
    static let epoch = Date().addingTimeInterval(-7 * 86_400)

    struct Entry {
        var minutes: Double
        var kind = "clean"
        var wall: Double? = 20
        var busy: Double? = 18
        var scheme: String? = "AcmeApp"
        var xcode: String? = "26.0"
        var commit: String? = nil
        var branch: String? = nil
        var machine: (model: String, cores: Int, gb: Int)? = ("Mac15,14", 28, 96)
    }

    /// Writes one entry and returns its id (`<yyyyMMdd-HHmmss>-<kind>`).
    @discardableResult
    static func save(_ entry: Entry, in directory: URL, file: StaticString = #filePath, line: UInt = #line) throws -> String {
        let model = SyntheticModel.make()
        let date = epoch.addingTimeInterval(entry.minutes * 60)
        var document = try ReportPipeline.run(model, options: .init(generatedAt: date)).document
        document.build.kind = entry.kind
        document.build.span = entry.wall
        document.build.busy = entry.busy
        document.build.scheme = entry.scheme
        document.xcode.value = entry.xcode
        var environment = EnvSnapshot()
        environment.hwModel = entry.machine?.model
        environment.logicalCPUCount = entry.machine?.cores
        environment.memoryBytes = entry.machine.map { Int64($0.gb) * 1_073_741_824 }
        if entry.commit != nil || entry.branch != nil {
            environment.git = GitInfo(branch: entry.branch, commit: entry.commit, dirty: false, remoteHost: nil)
        }
        document.environment = environment
        // One log per entry, or `History.save` would keep only the first of a repeated log.
        document.input.path = "/dd/Logs/Build/\(UUID().uuidString).xcactivitylog"
        let url = try History.save(document: document, model: model, directory: directory)
        return String(url.lastPathComponent.dropLast(".json.gz".count))
    }

    static func hash(_ seed: Character) -> String { String(repeating: String(seed), count: 40) }
}

extension XCTestCase {
    /// `<scratch>/history`, ready for `TrendFixture.save`.
    func makeHistoryDirectory() throws -> URL {
        let dir = try makeScratchDirectory().appendingPathComponent("history")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
