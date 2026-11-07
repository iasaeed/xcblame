import CryptoKit
import Foundation

// v0.6 lane B (docs/SCHEMA-v0.6.md "Verdict"; DESIGN §7.8 steps 4-6, the v0.4 noise model of §6.10): statistics of an
// arm, the timing verdict, the validity checks and the declared-effect table.
public enum VerifyVerdict {
    /// What the timing comparison of one unit gave.
    public struct Timing: Sendable, Equatable {
        public var verdict: VerifyDocument.Verdict
        public var deltaSeconds: Double?
        public var deltaPct: Double?
        public var noiseBand: Double?
    }

    /// Median and MAD of the samples' wall (nil without samples).
    public static func stats(_ walls: [Double]) -> (p50: Double?, mad: Double?) {
        (Stats.median(walls).map(Stats.round6), Stats.mad(walls).map(Stats.round6))
    }

    /// The §7.8 step 6 verdict over the samples of both arms: `indicative` when `runs` < `minRuns` or either arm has
    /// fewer than `minSamples` samples; otherwise band = max(`madMultiplier` × pooled MAD, `minPct` × A.p50), `kept` when
    /// B is faster beyond it, `reverted (slower)` when slower beyond it, else `reverted (within noise)` or, with
    /// `keepOnTie`, `kept` with `tie`.
    public static func timing(a: [Double], b: [Double], runs: Int, keepOnTie: Bool,
                              model: VerifyDocument.NoiseModel = .v06) -> Timing {
        let (aP50, aMad) = stats(a)
        let (bP50, bMad) = stats(b)
        guard let aP50, let bP50, let aMad, let bMad else {
            return Timing(verdict: .init(status: .indicative), deltaSeconds: nil, deltaPct: nil, noiseBand: nil)
        }
        let delta = bP50 - aP50
        let pct = aP50 > 0 ? delta / aP50 : nil
        let rounded = (Stats.round6(delta), pct.map(Stats.round6))
        guard runs >= model.minRuns, a.count >= model.minSamples, b.count >= model.minSamples else {
            return Timing(verdict: .init(status: .indicative), deltaSeconds: rounded.0, deltaPct: rounded.1, noiseBand: nil)
        }
        let band = max(model.madMultiplier * Stats.pooled(aMad, bMad), model.minPct * aP50)
        let verdict: VerifyDocument.Verdict
        if abs(delta) > band, delta < 0 {
            verdict = .init(status: .kept)
        } else if abs(delta) > band, delta > 0 {
            verdict = .init(status: .reverted, reason: .slower)
        } else if keepOnTie {
            verdict = .init(status: .kept, tie: true)
        } else {
            verdict = .init(status: .reverted, reason: .withinNoise)
        }
        return Timing(verdict: verdict, deltaSeconds: rounded.0, deltaPct: rounded.1, noiseBand: Stats.round6(band))
    }

    // MARK: - Hashes

    /// First 16 hex of SHA-256 over the sorted `target\tkind\tcount` lines.
    public static func taskKindsHash(_ kinds: [String: Int]) -> String {
        hash(kinds.map { "\($0.key)\t\($0.value)" }.sorted())
    }

    /// First 16 hex of SHA-256 over the sorted target names.
    public static func targetSetHash(_ targets: [String]) -> String { hash(Set(targets).sorted()) }

    private static func hash(_ lines: [String]) -> String {
        SHA256.hash(data: Data(lines.joined(separator: "\n").utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Declared effects

    /// Task kinds (rule names) a rule's fix adds or removes in a clean build by definition (§7.8 step 5): they may
    /// appear, disappear or change count. A difference in any other kind between the arms is `reverted (task set
    /// changed)`. A rule without an entry may change no kind. Taken from docs/RULES.md's fix column (fix round 2): only
    /// rules `verify` can measure (overlay or cli fixes) that the catalog implements; PHASE rules are `rec` and never
    /// verified, SET-012 (asset catalog variants) is not in the catalog yet.
    public static let declaredEffects: [String: Set<String>] = [
        "SET-001": swiftDriverKinds, // singlefile vs wholemodule: other Swift job shapes
        "SET-004": ["GenerateDSYMFile", "GenerateDsymFile"], // dwarf: no dSYM task
        "SET-005": ["CreateUniversalBinary", "SwiftMergeGeneratedHeaders", "GenerateTAPI"], // one arch: no lipo/merge
        "SET-009": swiftDriverKinds,
        "SET-011": ["Validate", "ValidateEmbeddedBinary"],
        "SET-013": swiftDriverKinds.union(["SwiftExplicitDependencyGeneratePcm", "SwiftExplicitDependencyCompileModuleFromInterface",
                                           "PrecompileModule", "ScanDependencies", "ExplicitModuleDependencies"]),
        "SET-014": ["PrecompileModule", "ScanDependencies", "SwiftExplicitDependencyGeneratePcm"],
        "SET-015": swiftDriverKinds,
        "SET-016": swiftDriverKinds.union(["CompileC", "PrecompileModule", "SwiftExplicitDependencyGeneratePcm"]),
        "SET-021": ["ProcessPCH", "ProcessPCH++"],
        "SET-022": ["WriteAuxiliaryFile"], // header maps are written as auxiliary files
        "SET-023": ["GenerateTAPI", "Ld", "SwiftEmitModule"],
        "SET-029": ["Strip"],
        // BUILD_LIBRARY_FOR_DISTRIBUTION = NO: no .swiftinterface emission and verification (rule names not yet seen in
        // a log; an unknown name only widens the allowance).
        "SET-032": ["SwiftVerifyEmittedModuleInterface", "SwiftVerifyEmittedPrivateModuleInterface", "SwiftEmitModule",
                    "Copy"],
    ]

    /// Rules whose fix changes the number of architectures built (docs/RULES.md: `ONLY_ACTIVE_ARCH`, `ARCHS`,
    /// `VALID_ARCHS`, `EXCLUDED_ARCHS`). Every per-arch task (the Swift driver's planning steps such as `SwiftDriver
    /// Compilation`, `ConstructStubExecutorLinkFileList`, compiles, links, copies, auxiliary files) runs once per
    /// architecture, so for them every kind compares by presence, not count (fix round 3): the compile and link work
    /// (`compileLinkKinds`) and every other kind of arm A must still be there in arm B, and B may add none; only the
    /// declared multi-arch-only kinds (`CreateUniversalBinary`, …) may disappear.
    public static let architectureCountRules: Set<String> = ["SET-005", "SET-006"]

    /// The compile and link work an architecture-count change must keep in every target that had it.
    public static let compileLinkKinds: Set<String> = ["SwiftCompile", "CompileC", "Ld"]

    /// True when a rule of `ruleIds` changes the number of architectures (counts are not compared).
    public static func architectureCount(_ ruleIds: [String]) -> Bool {
        ruleIds.contains { architectureCountRules.contains(RuleCatalog.resolve($0)) }
    }

    /// Explicit-module and implicit-module builds that run only when the arm's module cache lacks the module: the first
    /// clean build of a fresh per-arm DerivedData builds them, later ones do not, whatever the change (fix round 2:
    /// SET-004 was `reverted (task set changed)` on these alone). Never compared.
    public static let cacheDependentKinds: Set<String> = ["SwiftExplicitDependencyGeneratePcm",
                                                          "SwiftExplicitDependencyCompileModuleFromInterface",
                                                          "PrecompileModule", "GenerateSwiftModulesReport"]

    static let swiftDriverKinds: Set<String> = ["SwiftCompile", "SwiftDriver", "SwiftDriverJobDiscovery",
                                                "SwiftEmitModule", "SwiftMergeGeneratedHeaders"]

    /// The kinds every rule of `ruleIds` declares (may appear, disappear or change count).
    public static func declared(for ruleIds: [String]) -> Set<String> {
        ruleIds.reduce(into: Set<String>()) { $0.formUnion(declaredEffects[$1] ?? []) }
    }

    /// `target\tkind` keys that differ between `a` and `b`: kinds in `allowed` and the cache-dependent kinds left out;
    /// with `presenceOnly` (an architecture-count rule) a kind differs only when one arm has it and the other not.
    public static func differingKinds(_ a: [String: Int], _ b: [String: Int], allowed: Set<String>,
                                      presenceOnly: Bool = false) -> [String] {
        Set(a.keys).union(b.keys).filter { key in
            let kind = key.split(separator: "\t", maxSplits: 1).last.map(String.init) ?? key
            guard !allowed.contains(kind), !cacheDependentKinds.contains(kind) else { return false }
            if presenceOnly { return ((a[key] ?? 0) > 0) != ((b[key] ?? 0) > 0) }
            return a[key] != b[key]
        }.sorted()
    }

    /// The `taskKinds` failure in at most two lines: up to three differing kinds with their counts, then the effect a
    /// rule would have to declare for them (`rules` are the unit's).
    public static func taskKindsFailure(_ keys: [String], reference: [String: Int], samples: [[String: Int]],
                                        rules: [String]) -> String {
        func count(_ key: String, _ kinds: [String: Int]?) -> Int { kinds?[key] ?? 0 }
        let b = samples.first { sample in keys.contains { count($0, sample) != count($0, reference) } }
        let shown = keys.prefix(3).map { key -> String in
            let (before, after) = (count(key, reference), count(key, b))
            let what = before == 0 ? "only in B" : after == 0 ? "missing in B" : "\(before) → \(after)"
            return key.replacingOccurrences(of: "\t", with: " ") + " (\(what))"
        }
        let countOnly = keys.allSatisfy { count($0, reference) > 0 && count($0, b) > 0 }
        let need = countOnly
            ? "only counts changed: that needs an architecture-count effect (VerifyVerdict.architectureCountRules)"
            : "that needs the kinds in \(rules.joined(separator: "+"))'s declared effect (VerifyVerdict.declaredEffects)"
        return "arm B executed other task kinds: " + shown.joined(separator: ", ") + (keys.count > 3 ? ", …" : "")
            + ";\n" + need + " if the fix changes them by definition"
    }
}
