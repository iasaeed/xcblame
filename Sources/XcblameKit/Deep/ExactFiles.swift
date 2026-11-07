import Foundation

// v0.5 lane A (docs/SCHEMA-v0.5.md "Deep"): `--deep --exact-files` (DESIGN §6.4).
public enum ExactFiles {
    /// How many of the longest batches have their target rebuilt.
    public static let topK = 5

    public struct Plan: Sendable, Equatable {
        /// Targets of the top-K batches, rebuilt with `SWIFT_ENABLE_BATCH_MODE=NO` in the deep DerivedData.
        public var targets: [String]
        /// Wrapper lines added for the rebuild.
        public var lines: [String]
        /// States that the build shape changed.
        public var note: String

        public init(targets: [String], lines: [String], note: String) {
            self.targets = targets
            self.lines = lines
            self.note = note
        }
    }

    /// The rebuild plan from the batch rows of a first deep build: the targets of the `topK` longest `batch` rows, in
    /// that order, without duplicates. An xcconfig cannot be conditional on a target, so the lines turn batch mode off
    /// through a per-target variable (`SWIFT_ENABLE_BATCH_MODE = $(XCBLAME_BATCH_MODE_$(TARGET_NAME:c99extidentifier):default=$(inherited))`
    /// plus `XCBLAME_BATCH_MODE_<target> = NO` per chosen target; verified with `-showBuildSettings` on Xcode 26.0.1:
    /// a target without the variable keeps its own value, a project's `NO` included): only the chosen targets' Swift
    /// tasks change signature, so the incremental rebuild in the same deep DerivedData recompiles just them. A chosen
    /// target whose c99 identifier is another target's too (`My-App` / `My_App`) would switch both, so it is refused
    /// with a note. No batch rows: no targets, no lines, and the note says nothing was rebuilt.
    public static func plan(files: [ReportDocument.FileRow], topK: Int = ExactFiles.topK) throws -> Plan {
        let batches = files.filter { $0.granularity == "batch" }
            .sorted { $0.seconds != $1.seconds ? $0.seconds > $1.seconds : $0.path < $1.path }
        var chosen: [String] = []
        for row in batches.prefix(topK) {
            guard let target = row.target, !chosen.contains(target) else { continue }
            chosen.append(target)
        }
        var sharing: [String: Set<String>] = [:]
        for name in Set(files.compactMap(\.target)) { sharing[c99Identifier(name), default: []].insert(name) }
        let refused = chosen.filter { (sharing[c99Identifier($0)]?.count ?? 0) > 1 }
        let targets = chosen.filter { !refused.contains($0) }
        let collision = refused.isEmpty ? "" : "; not rebuilt: " + refused.map { name in
            let others = (sharing[c99Identifier(name)] ?? []).subtracting([name]).sorted().joined(separator: ", ")
            return "\(name) (its setting name XCBLAME_BATCH_MODE_\(c99Identifier(name)) is also \(others)'s)"
        }.joined(separator: ", ")
        guard !targets.isEmpty else {
            return Plan(targets: [], lines: [], note: (chosen.isEmpty
                ? "--exact-files: the first deep build has no batch compile, so nothing was rebuilt"
                : "--exact-files: nothing was rebuilt") + collision + "; the build shape did not change")
        }
        let lines = ["SWIFT_ENABLE_BATCH_MODE = $(XCBLAME_BATCH_MODE_$(TARGET_NAME:c99extidentifier):default=$(inherited))"]
            + targets.map { "XCBLAME_BATCH_MODE_\(c99Identifier($0)) = NO" }
        return Plan(targets: targets, lines: lines, note: "--exact-files: the build shape changed: "
            + targets.joined(separator: ", ") + " rebuilt without batch mode (SWIFT_ENABLE_BATCH_MODE = NO) in the deep "
            + "DerivedData; this report is of that rebuild, whose file rows of those targets are exact" + collision)
    }

    /// Xcode's `c99extidentifier`: every character outside `[A-Za-z0-9_]` becomes `_`, a leading digit gets a `_`.
    static func c99Identifier(_ name: String) -> String {
        var out = String(name.map { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") ? $0 : "_" })
        if out.first?.isNumber == true { out = "_" + out }
        return out
    }
}
