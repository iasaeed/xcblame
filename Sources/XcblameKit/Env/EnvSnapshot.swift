import Foundation

/// Minimal environment snapshot (DESIGN §5.9). Every probe has a 2 s timeout; a probe that fails, times out or is not
/// available on this machine leaves its field nil, which reports render as "unknown".
public struct EnvSnapshot: Codable, Sendable, Equatable {
    /// `xcodebuild -version`, e.g. `Xcode 26.0\nBuild version 17A324`.
    public var xcodebuildVersion: String?
    /// `xcode-select -p`.
    public var developerDir: String?
    public var macOSProductVersion: String?
    public var macOSBuildVersion: String?
    public var hwModel: String?
    public var logicalCPUCount: Int?
    public var memoryBytes: Int64?
    public var performanceCores: Int?
    public var efficiencyCores: Int?
    /// `sysctl.proc_translated`: true when running under Rosetta.
    public var processTranslated: Bool?
    /// Detected CI provider; nil when no CI variable is set.
    public var ciProvider: String?
    /// Branch, commit and dirty flag of the repository in the current directory (v0.4); omitted from the JSON when nil,
    /// like every other member here.
    public var git: GitInfo?

    public init() {}

    /// Probe signature: argv in, trimmed stdout or nil out. Injectable for tests.
    public typealias Probe = @Sendable ([String]) -> String?

    public static func capture(environment: [String: String] = ProcessInfo.processInfo.environment,
                               probe: Probe = { runProbe($0, timeout: 2) }) -> EnvSnapshot {
        var snapshot = EnvSnapshot()
        snapshot.xcodebuildVersion = probe(["xcodebuild", "-version"])
        snapshot.developerDir = probe(["xcode-select", "-p"])
        if let text = probe(["sw_vers"]) {
            let fields = keyValues(text)
            snapshot.macOSProductVersion = fields["ProductVersion"]
            snapshot.macOSBuildVersion = fields["BuildVersion"]
        }
        func sysctl(_ key: String) -> String? { probe(["sysctl", "-n", key]) }
        snapshot.hwModel = sysctl("hw.model")
        snapshot.logicalCPUCount = sysctl("hw.ncpu").flatMap { Int($0) }
        snapshot.memoryBytes = sysctl("hw.memsize").flatMap { Int64($0) }
        snapshot.performanceCores = sysctl("hw.perflevel0.physicalcpu").flatMap { Int($0) }
        snapshot.efficiencyCores = sysctl("hw.perflevel1.physicalcpu").flatMap { Int($0) }
        snapshot.processTranslated = sysctl("sysctl.proc_translated").flatMap { Int($0) }.map { $0 != 0 }
        snapshot.ciProvider = ciProvider(environment: environment)
        snapshot.git = GitInfo.capture(probe: probe)
        return snapshot
    }

    /// CI provider from environment variables, most specific first; the bare `CI` flag comes last.
    public static func ciProvider(environment env: [String: String]) -> String? {
        func set(_ key: String) -> Bool { !(env[key] ?? "").isEmpty }
        let table: [(variable: String, name: String)] = [
            ("GITHUB_ACTIONS", "github-actions"), ("BITRISE_IO", "bitrise"),
            ("CI_XCODE_CLOUD", "xcode-cloud"), ("XCODE_CLOUD", "xcode-cloud"),
            ("GITLAB_CI", "gitlab-ci"), ("BUILDKITE", "buildkite"), ("JENKINS_URL", "jenkins"),
            ("CIRCLECI", "circleci"), ("CI", "ci"),
        ]
        return table.first { set($0.variable) }?.name
    }

    /// `sw_vers` style `Key:\tvalue` lines.
    static func keyValues(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            guard let colon = line.firstIndex(of: ":") else { continue }
            result[String(line[..<colon])] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        return result
    }
}
