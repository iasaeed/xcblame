import XCTest
@testable import XcblameKit

/// The verdict of docs/SCHEMA-v0.6.md "Verdict": the v0.4 noise model (band = max(3 × pooled MAD, 2 % × A.p50)),
/// `indicative`, `--keep-on-tie`, the hashes and the declared-effect table.
final class VerifyVerdictTests: XCTestCase {
    func testBandIsTheLargerOfMADAndTwoPercent() {
        // MAD 0 on both sides: the 2 % floor (0.2 s of 10 s) decides.
        let a = [10.0, 10.0, 10.0, 10.0]
        XCTAssertEqual(VerifyVerdict.timing(a: a, b: [9.75, 9.75, 9.75, 9.75], runs: 4, keepOnTie: false).verdict.status, .kept)
        let atFloor = VerifyVerdict.timing(a: a, b: [9.8, 9.8, 9.8, 9.8], runs: 4, keepOnTie: false)
        XCTAssertEqual(atFloor.noiseBand ?? 0, 0.2, accuracy: 1e-9)
        XCTAssertEqual(atFloor.verdict, .init(status: .reverted, reason: .withinNoise), "|Δ| must exceed the band")
        XCTAssertEqual(VerifyVerdict.timing(a: a, b: [10.25, 10.25, 10.25, 10.25], runs: 4, keepOnTie: false).verdict,
                       .init(status: .reverted, reason: .slower))

        // MAD 0.5 on both sides: band = 3 × 0.5 = 1.5 s beats the 0.2 s floor.
        let noisyA = [9.5, 10.0, 10.5, 10.0, 9.5, 10.5]
        let noisyB = noisyA.map { $0 - 1.4 }
        let timing = VerifyVerdict.timing(a: noisyA, b: noisyB, runs: 6, keepOnTie: false)
        XCTAssertEqual(timing.noiseBand ?? 0, 1.5, accuracy: 1e-9)
        XCTAssertEqual(timing.verdict, .init(status: .reverted, reason: .withinNoise))
        XCTAssertEqual(VerifyVerdict.timing(a: noisyA, b: noisyB, runs: 6, keepOnTie: true).verdict, .init(status: .kept, tie: true))
        XCTAssertEqual(VerifyVerdict.timing(a: noisyA, b: noisyA.map { $0 - 1.6 }, runs: 6, keepOnTie: false).verdict.status, .kept)
    }

    func testPooledMADUsesBothArms() {
        // madA 0, madB 0.4: pooled = √(0.16 / 2) ≈ 0.283, band ≈ 0.849.
        let timing = VerifyVerdict.timing(a: [10, 10, 10, 10], b: [9.6, 9.0, 8.6, 9.0, 9.4], runs: 5, keepOnTie: false)
        XCTAssertEqual(timing.noiseBand ?? 0, 3 * (0.16 / 2).squareRoot(), accuracy: 1e-6)
        XCTAssertEqual(timing.deltaSeconds ?? 0, -1.0, accuracy: 1e-9)
        XCTAssertEqual(timing.deltaPct ?? 0, -0.1, accuracy: 1e-9)
        XCTAssertEqual(timing.verdict.status, .kept)
    }

    func testIndicativeBelowFourRunsOrThreeSamples() {
        let a = [10.0, 10.0, 10.0]
        let b = [5.0, 5.0, 5.0]
        XCTAssertEqual(VerifyVerdict.timing(a: a, b: b, runs: 3, keepOnTie: false).verdict, .init(status: .indicative))
        XCTAssertEqual(VerifyVerdict.timing(a: a, b: [5.0, 5.0], runs: 4, keepOnTie: false).verdict.status, .indicative)
        XCTAssertNil(VerifyVerdict.timing(a: a, b: b, runs: 3, keepOnTie: false).noiseBand)
        XCTAssertEqual(VerifyVerdict.timing(a: a, b: b, runs: 4, keepOnTie: false).verdict.status, .kept)
        XCTAssertEqual(VerifyVerdict.timing(a: [], b: b, runs: 5, keepOnTie: false).verdict.status, .indicative)
        XCTAssertEqual(VerifyDocument.NoiseModel.v06, .init(madMultiplier: 3, minPct: 0.02, minSamples: 3, minRuns: 4))
    }

    func testHashesAreOrderIndependentSixteenHex() {
        let one = VerifyVerdict.taskKindsHash(["A\tSwiftCompile": 3, "B\tLd": 1])
        XCTAssertEqual(one, VerifyVerdict.taskKindsHash(["B\tLd": 1, "A\tSwiftCompile": 3]))
        XCTAssertNotEqual(one, VerifyVerdict.taskKindsHash(["A\tSwiftCompile": 4, "B\tLd": 1]))
        XCTAssertEqual(one.count, 16)
        XCTAssertTrue(one.allSatisfy(\.isHexDigit))
        XCTAssertEqual(VerifyVerdict.targetSetHash(["B", "A", "A"]), VerifyVerdict.targetSetHash(["A", "B"]))
    }

    func testDeclaredEffectsFilterOnlyTheirKinds() {
        XCTAssertEqual(VerifyVerdict.declared(for: ["SET-004"]), ["GenerateDSYMFile", "GenerateDsymFile"])
        XCTAssertTrue(VerifyVerdict.declared(for: ["SET-030"]).isEmpty)
        let a = ["App\tGenerateDSYMFile": 2, "App\tLd": 1]
        let b = ["App\tLd": 2]
        XCTAssertEqual(VerifyVerdict.differingKinds(a, b, allowed: ["GenerateDSYMFile"]), ["App\tLd"])
        XCTAssertEqual(VerifyVerdict.differingKinds(a, b, allowed: []), ["App\tGenerateDSYMFile", "App\tLd"])
        XCTAssertTrue(VerifyVerdict.differingKinds(a, a, allowed: []).isEmpty)
        for rule in VerifyVerdict.declaredEffects.keys { XCTAssertNotNil(RuleCatalog.spec(rule), rule) }
        for rule in VerifyVerdict.architectureCountRules { XCTAssertNotNil(RuleCatalog.spec(rule), rule) }
        XCTAssertTrue(VerifyVerdict.architectureCount(["SET-005"]))
        XCTAssertFalse(VerifyVerdict.architectureCount(["SET-004"]))
    }

    /// Architecture-count rules compare kinds by presence; cache-dependent module builds are never compared.
    func testArchitectureCountComparesByPresenceAndCacheKindsAreIgnored() {
        let a = ["App\tSwiftCompile": 80, "App\tLd": 2, "App\tCreateUniversalBinary": 1, "App\tSwiftDriver Compilation": 2]
        let b = ["App\tSwiftCompile": 40, "App\tLd": 1, "App\tSwiftDriver Compilation": 1]
        let allowed = VerifyVerdict.declared(for: ["SET-005"])
        XCTAssertTrue(VerifyVerdict.differingKinds(a, b, allowed: allowed, presenceOnly: true).isEmpty)
        XCTAssertEqual(VerifyVerdict.differingKinds(a, ["App\tLd": 1, "App\tSwiftDriver Compilation": 1], allowed: allowed,
                                                    presenceOnly: true),
                       ["App\tSwiftCompile"], "the compile work that disappears is still a change")
        XCTAssertEqual(VerifyVerdict.differingKinds(a, b.merging(["App\tPhaseScriptExecution": 1]) { $1 }, allowed: allowed,
                                                    presenceOnly: true),
                       ["App\tPhaseScriptExecution"], "a kind only B runs is still a change")
        XCTAssertEqual(VerifyVerdict.differingKinds(a, b, allowed: []),
                       ["App\tCreateUniversalBinary", "App\tLd", "App\tSwiftCompile", "App\tSwiftDriver Compilation"],
                       "without an architecture-count rule: every count")
        let cold = ["App\tLd": 1, "explicit modules\tSwiftExplicitDependencyGeneratePcm": 30,
                    "build system\tGenerateSwiftModulesReport": 1]
        XCTAssertTrue(VerifyVerdict.differingKinds(cold, ["App\tLd": 1], allowed: []).isEmpty)
    }

    /// The failure detail: at most two lines, the differing kinds with counts, and the effect a rule would need.
    func testTaskKindsFailureNamesTheNeededEffect() {
        let reference = ["App\tSwiftDriver Compilation": 2, "App\tLd": 2]
        let counts = VerifyVerdict.taskKindsFailure(["App\tLd", "App\tSwiftDriver Compilation"], reference: reference,
                                                    samples: [["App\tSwiftDriver Compilation": 1, "App\tLd": 1]],
                                                    rules: ["SET-030"])
        XCTAssertLessThanOrEqual(counts.components(separatedBy: "\n").count, 2)
        XCTAssertTrue(counts.hasPrefix("arm B executed other task kinds: App Ld (2 → 1), App SwiftDriver Compilation (2 → 1)"),
                      counts)
        XCTAssertTrue(counts.contains("architecture-count effect"), counts)
        let added = VerifyVerdict.taskKindsFailure(["App\tPhaseScriptExecution"], reference: reference,
                                                   samples: [["App\tPhaseScriptExecution": 1]], rules: ["SET-030"])
        XCTAssertTrue(added.contains("App PhaseScriptExecution (only in B)") && added.contains("SET-030's declared effect"), added)
    }
}
