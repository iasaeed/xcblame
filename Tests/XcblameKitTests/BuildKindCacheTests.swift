import XCTest
@testable import XcblameKit

/// `BuildKind.cachedOrPreviews` (DESIGN §6.7): `previews` from the Previews arena (MV-17 open: expected signals),
/// `cached` when the build-level cache hits > 0; V11 accepts both on their own evidence.
final class BuildKindCacheTests: XCTestCase {
    private let counts = BuildKindResult.Counts(executed: 10, reused: 0, compileExecuted: 5, descriptionTaskExecuted: true,
                                                descriptionCreated: true, cleanActionShape: false)
    private let model = SyntheticModel.make()

    private func request(_ raw: [String: String]) -> BuildDescription.BuildRequest {
        .init(action: "build", enableIndexBuildArena: false, raw: raw)
    }

    func testCachedNeedsHits() throws {
        let hit = ReportDocument.BuildCache(hits: 3, misses: 1, replayedTasksHeuristic: nil, source: "buildOperationMetrics")
        let kind = try XCTUnwrap(BuildKind.cachedOrPreviews(model: model, counts: counts, request: nil, cache: hit,
                                                            descriptionDirectory: nil))
        XCTAssertEqual(kind.kind, "cached")
        XCTAssertEqual(kind.evidence.first, "BuildOperationMetrics: 3 cache hit(s), 1 miss(es)")
        XCTAssertEqual(Validator.checkV11(kind).status, .pass)
        let remarks = ReportDocument.BuildCache(hits: 2, misses: 0, replayedTasksHeuristic: nil, source: "casRemarks")
        XCTAssertEqual(BuildKind.cachedOrPreviews(model: model, counts: counts, request: nil, cache: remarks,
                                                  descriptionDirectory: nil)?.evidence.first,
                       "task output \"Cache hit\": 2 cache hit(s), 0 miss(es)")
        let misses = ReportDocument.BuildCache(hits: 0, misses: 9, replayedTasksHeuristic: nil, source: "buildOperationMetrics")
        XCTAssertNil(BuildKind.cachedOrPreviews(model: model, counts: counts, request: nil, cache: misses,
                                                descriptionDirectory: nil))
        XCTAssertNil(BuildKind.cachedOrPreviews(model: model, counts: counts, request: nil, cache: nil,
                                                descriptionDirectory: nil))
    }

    func testPreviewsSignalsWinOverTheCache() throws {
        let hit = ReportDocument.BuildCache(hits: 3, misses: 0, replayedTasksHeuristic: nil, source: "buildOperationMetrics")
        let byCommand = BuildKind.cachedOrPreviews(model: model, counts: counts,
                                                   request: request(["buildCommand.command": "preview"]), cache: hit,
                                                   descriptionDirectory: nil)
        XCTAssertEqual(byCommand?.kind, "previews")
        XCTAssertEqual(byCommand?.evidence, ["build-request.json buildCommand.command=preview (heuristic: the Previews "
            + "arena layout, MV-17 unconfirmed)"])
        let byArena = BuildKind.cachedOrPreviews(
            model: model, counts: counts,
            request: request(["parameters.arenaInfo.buildIntermediatesPath": "/DD/Build/Intermediates.noindex/Previews/App/Intermediates.noindex"]),
            cache: nil, descriptionDirectory: nil)
        XCTAssertEqual(byArena?.kind, "previews")
        let byDirectory = try XCTUnwrap(BuildKind.cachedOrPreviews(
            model: model, counts: counts, request: nil, cache: nil,
            descriptionDirectory: URL(fileURLWithPath: "/DD/Build/Intermediates.noindex/Previews/App/XCBuildData/x.xcbuilddata")))
        XCTAssertEqual(byDirectory.kind, "previews")
        XCTAssertEqual(Validator.checkV11(byDirectory).status, .pass)
        XCTAssertNil(BuildKind.cachedOrPreviews(model: model, counts: counts,
                                                request: request(["buildCommand.command": "build"]), cache: nil,
                                                descriptionDirectory: URL(fileURLWithPath: "/DD/Build/Intermediates.noindex/XCBuildData")))
    }

    /// Code review v0.5: only Xcode's arena layout counts (`Previews` right under `Intermediates.noindex` or
    /// `UserData`); a DerivedData the user named `~/Previews/dd` is an ordinary build.
    func testPreviewsNeedsTheArenaLayoutNotASubstring() {
        func kind(_ raw: [String: String] = [:], directory: String? = nil) -> String? {
            BuildKind.cachedOrPreviews(model: model, counts: counts, request: raw.isEmpty ? nil : request(raw), cache: nil,
                                       descriptionDirectory: directory.map { URL(fileURLWithPath: $0) })?.kind
        }
        XCTAssertNil(kind(["parameters.arenaInfo.derivedDataPath": "/Users/me/Previews/dd"]))
        XCTAssertNil(kind(["parameters.arenaInfo.buildIntermediatesPath": "/Users/me/Previews/dd/Build/Intermediates.noindex"]))
        XCTAssertNil(kind(directory: "/Users/me/Previews/dd/Build/Intermediates.noindex/XCBuildData/x.xcbuilddata"))
        XCTAssertNil(kind(["parameters.arenaInfo.derivedDataPath": "/Users/me/Library/Developer/Xcode/UserData/PreviewsOld"]))
        XCTAssertEqual(kind(["parameters.arenaInfo.derivedDataPath":
                                "/Users/me/Library/Developer/Xcode/UserData/Previews/Simulator Devices/X/data"]), "previews")
        XCTAssertEqual(kind(directory: "/DD/Build/Intermediates.noindex/Previews/App/XCBuildData/x.xcbuilddata"), "previews")
    }

    func testV11RejectsTheNewKindsWithoutTheirEvidence() {
        let cached = BuildKindResult(kind: "cached", evidence: ["0 reused task(s)"], reason: nil, counts: counts)
        XCTAssertEqual(Validator.checkV11(cached).status, .fail("cached build without cache-hit evidence"))
        let previews = BuildKindResult(kind: "previews", evidence: ["something"], reason: nil, counts: counts)
        XCTAssertEqual(Validator.checkV11(previews).status, .fail("previews build without Previews-arena evidence"))
    }

    func testClassifyRunsTheLaneCBlockBeforeTheCountRules() {
        let line = Timing.timeline(model)
        let hit = ReportDocument.BuildCache(hits: 1, misses: 0, replayedTasksHeuristic: nil, source: "casRemarks")
        XCTAssertEqual(BuildKind.classify(model: model, counted: line.counted, reused: 0, request: nil, cache: hit).kind,
                       "cached")
        XCTAssertEqual(BuildKind.classify(model: model, counted: line.counted, reused: 0, request: nil).kind, "clean")
    }
}
