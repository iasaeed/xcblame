import Foundation

// v0.5 lane A (docs/SCHEMA-v0.5.md "Deep"): the flags `build --deep` injects (DESIGN §5.8).

/// `--deep-scope` values.
public enum DeepScope: String, Sendable, CaseIterable, Codable {
    case swift, clang

    /// `swift,clang` → `[.swift, .clang]` in that canonical order, duplicates removed. Unknown names are a usage error.
    public static func parse(_ text: String) throws -> [DeepScope] {
        var found = Set<DeepScope>()
        for part in text.split(separator: ",", omittingEmptySubsequences: false) {
            let name = part.trimmingCharacters(in: .whitespaces)
            guard let scope = DeepScope(rawValue: name) else {
                throw XcblameError.usage("--deep-scope: unknown scope '\(name)' (known: swift, clang)")
            }
            found.insert(scope)
        }
        return allCases.filter(found.contains)
    }
}

/// What `--deep` adds to the build: wrapper xcconfig lines and the flag list the report shows.
public struct DeepFlags: Sendable, Equatable {
    public var scope: [DeepScope]
    public var exactFiles: Bool
    /// Wrapper xcconfig lines, each `KEY = $(inherited) <flags>` (`OTHER_SWIFT_FLAGS`, `OTHER_CFLAGS`), in order.
    public var lines: [String]
    /// The flags in `lines`, one entry per flag as the report shows it (`-Xfrontend -debug-time-function-bodies`).
    public var injected: [String]
    /// Flags the toolchain does not support (probe), with the reason (`deep.flagsDropped`).
    public var dropped: [ReportDocument.Deep.DroppedFlag]
    /// Supported flags left out by default, with the reason (`deep.flagsNotInjected`: the `-warn-long-*` pair).
    public var notInjected: [ReportDocument.Deep.DroppedFlag]

    public init(scope: [DeepScope], exactFiles: Bool, lines: [String], injected: [String],
                dropped: [ReportDocument.Deep.DroppedFlag], notInjected: [ReportDocument.Deep.DroppedFlag] = []) {
        self.scope = scope
        self.exactFiles = exactFiles
        self.lines = lines
        self.injected = injected
        self.dropped = dropped
        self.notInjected = notInjected
    }

    /// The §5.8 flags for `scope` that `probe` says the toolchain supports: Swift `-debug-time-function-bodies`,
    /// `-debug-time-expression-type-checking` and `-stats-output-dir <statsDir>` (warn-long off by default: listed in
    /// `notInjected`); clang `-ftime-trace -ftime-trace-granularity=<traceGranularityMicros>`. A flag the probe does
    /// not find is dropped with the reason; a scope left without flags has no line.
    public static func plan(scope: [DeepScope], exactFiles: Bool, probe: ToolchainProbe.Result, statsDir: URL,
                            traceGranularityMicros: Int = 500) throws -> DeepFlags {
        if scope.contains(.swift) { try WrapperXCConfig.requireExpressible(statsDir.path, what: "the deep stats folder") }
        var lines: [String] = []
        var injected: [String] = []
        var dropped: [ReportDocument.Deep.DroppedFlag] = []
        var notInjected: [ReportDocument.Deep.DroppedFlag] = []
        func reason(_ scope: DeepScope) -> String {
            let tool = scope == .swift ? "swift-frontend (-help, -help-hidden)" : "clang (--help)"
            let failed = scope == .swift ? probe.swiftFrontendHelp == nil : probe.clangHelp == nil
            return failed ? "toolchain probe failed: \(tool) gave no help text" : "not supported by this toolchain: not in \(tool)"
        }
        if scope.contains(.swift) {
            // (flag as delivered, the option name the help text must list)
            let candidates: [(delivered: [String], name: String)] = [
                (["-Xfrontend", "-debug-time-function-bodies"], "-debug-time-function-bodies"),
                (["-Xfrontend", "-debug-time-expression-type-checking"], "-debug-time-expression-type-checking"),
                (["-Xfrontend", "-stats-output-dir", "-Xfrontend", xcconfigQuoted(statsDir.path)], "-stats-output-dir"),
            ]
            var parts: [String] = []
            for candidate in candidates {
                let flag = candidate.delivered.joined(separator: " ")
                if try ToolchainProbe.supports(candidate.name, scope: .swift, in: probe) {
                    parts.append(flag)
                    injected.append(flag)
                } else {
                    dropped.append(.init(flag: flag, reason: reason(.swift)))
                }
            }
            for name in ["-warn-long-function-bodies", "-warn-long-expression-type-checking"] {
                notInjected.append(.init(flag: "-Xfrontend \(name)=<ms>",
                                     reason: "off by default: warnings-as-errors projects would fail ([OC] A20)"))
            }
            if !parts.isEmpty { lines.append("OTHER_SWIFT_FLAGS = $(inherited) " + parts.joined(separator: " ")) }
        }
        if scope.contains(.clang) {
            var parts: [String] = []
            for flag in ["-ftime-trace", "-ftime-trace-granularity=\(traceGranularityMicros)"] {
                if try ToolchainProbe.supports(flag, scope: .clang, in: probe) {
                    parts.append(flag)
                    injected.append(flag)
                } else {
                    dropped.append(.init(flag: flag, reason: reason(.clang)))
                }
            }
            // The granularity alone means nothing.
            if parts.contains("-ftime-trace") {
                lines.append("OTHER_CFLAGS = $(inherited) " + parts.joined(separator: " "))
            } else if !parts.isEmpty {
                injected.removeAll { parts.contains($0) }
                dropped += parts.map { .init(flag: $0, reason: "-ftime-trace itself is not supported") }
            }
        }
        return DeepFlags(scope: scope, exactFiles: exactFiles, lines: lines, injected: injected, dropped: dropped,
                         notInjected: notInjected)
    }

    /// An xcconfig list value: quoted when it holds a space.
    static func xcconfigQuoted(_ value: String) -> String {
        value.contains(" ") ? "\"\(value)\"" : value
    }
}

/// Everything about one `--deep` build that the report pipeline needs (`ReportPipeline.Options.deep`): the flags, the
/// deep DerivedData, where the readers look, and the oracle check of the wrapper.
public struct DeepRun: Sendable, Equatable {
    public var flags: DeepFlags
    /// False when `--deep` aborted before building (MV-3 lost flag, failed probe); `notes` says why.
    public var enabled: Bool
    public var derivedData: URL
    public var derivedDataBytes: Int64?
    /// `-stats-output-dir` folder (inside `derivedData`).
    public var statsDir: URL
    public var wrapper: URL?
    /// `<target>: <KEY>` the oracle check found shadowed.
    public var shadowed: [String]
    public var exactFiles: ExactFiles.Plan?
    public var notes: [String]

    public init(flags: DeepFlags, enabled: Bool, derivedData: URL, derivedDataBytes: Int64?, statsDir: URL,
                wrapper: URL?, shadowed: [String], exactFiles: ExactFiles.Plan?, notes: [String]) {
        self.flags = flags
        self.enabled = enabled
        self.derivedData = derivedData
        self.derivedDataBytes = derivedDataBytes
        self.statsDir = statsDir
        self.wrapper = wrapper
        self.shadowed = shadowed
        self.exactFiles = exactFiles
        self.notes = notes
    }

    /// The report's `deep` member (a plain mapping; paths are redacted later with the rest of the document).
    public func member(sources: ReportDocument.Deep.Sources?) -> ReportDocument.Deep {
        ReportDocument.Deep(
            enabled: enabled, scope: flags.scope.map(\.rawValue), flagsInjected: flags.injected,
            flagsDropped: flags.dropped, flagsNotInjected: flags.notInjected, shadowed: shadowed, derivedData: derivedData.path,
            derivedDataBytes: derivedDataBytes, wrapper: wrapper?.path,
            exactFiles: exactFiles.map { ReportDocument.Deep.ExactFiles(rebuiltTargets: $0.targets, note: $0.note) },
            sources: sources, notes: notes)
    }
}
