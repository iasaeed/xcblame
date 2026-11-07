import XCTest
@testable import XcblameKit

final class GraphDescriptionTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("xcblame-graph-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    func testLoadsGzippedManifestTargetGraphRequestAndSignature() throws {
        let description = try BuildDescription.load(directory: GraphFixtures.descriptionDD)
        XCTAssertEqual(description.commands.count, 753)
        XCTAssertEqual(description.signature, "05e6f8da62523e252c9ce2f537414df7")
        XCTAssertEqual(description.buildRequest.action, "build")
        XCTAssertEqual(description.buildRequest.enableIndexBuildArena, false)
        XCTAssertEqual(description.buildRequest.raw["buildCommand.command"], "build")
        XCTAssertEqual(description.buildRequest.raw["buildCommand.style"], "buildOnly")
        XCTAssertTrue(description.targetGraph.contains(.init(from: "LocalizeCore", to: "SwiftSyntax")))
        XCTAssertTrue(description.targetGraph.contains(.init(from: "AcmeApp", to: "LocalizeCore")))
        XCTAssertEqual(Set(description.commands.map(\.key)).count, description.commands.count)
        let driver = try XCTUnwrap(description.commands.first { $0.tool == "swift-driver-compilation" })
        XCTAssertFalse(driver.inputs.isEmpty)
        XCTAssertFalse(driver.outputs.isEmpty)
    }

    func testLoadsPlainManifestWithoutSignature() throws {
        let description = try BuildDescription.load(directory: GraphFixtures.description26)
        XCTAssertEqual(description.commands.count, 747)
        XCTAssertNil(description.signature, "the research-session manifest has no SIGNATURE file")
        XCTAssertTrue(description.targetGraph.isEmpty)
        XCTAssertNil(description.buildRequest.action)
    }

    func testLoadFailsWithoutManifest() {
        XCTAssertThrowsError(try BuildDescription.load(directory: scratch))
    }

    /// The cli-xcode26 manifest is the 20E8B73D build's description (signature 6f0b463d in the log): it covers 100 %
    /// of the log's planned keyed tasks (212, the count DESIGN §5.6 records), not by signature (no SIGNATURE file).
    func testResearchManifestBelongsToTheCleanXcode26Log() throws {
        let model = try GraphFixtures.model(GraphFixtures.clean26)
        XCTAssertEqual(BuildDescriptionLocator.signature(of: model), "6f0b463d2f2edd5a58b553713dc8313d")
        let description = try BuildDescription.load(directory: GraphFixtures.description26)
        let coverage = BuildDescriptionLocator.coverage(of: description, model: model)
        XCTAssertEqual(coverage.matched, 212)
        XCTAssertEqual(try XCTUnwrap(coverage.share), 1.0, accuracy: 1e-9)
    }

    func testExplicitDescriptionIsASnapshotWithCoverageNotes() throws {
        let model = try GraphFixtures.model(GraphFixtures.cleanDD)
        let found = try XCTUnwrap(BuildDescriptionLocator.find(model: model, logURL: GraphFixtures.cleanDD,
                                                               explicit: GraphFixtures.descriptionDD,
                                                               snapshotsDir: nil))
        XCTAssertEqual(found.basis, "snapshot")
        XCTAssertTrue(found.notes.contains { $0.contains("218 of 218 planned keyed tasks") }, "\(found.notes)")
    }

    func testSnapshotFolderIsFoundByLogUUID() throws {
        let snapshots = scratch.appendingPathComponent("snapshots")
        let dir = snapshots.appendingPathComponent("5E3BDB3A-008A-466D-A419-CB4D4E8CED29")
        try copyDescription(from: GraphFixtures.descriptionDD, to: dir, signatureFile: false)
        let model = try GraphFixtures.model(GraphFixtures.cleanDD)
        let found = try XCTUnwrap(BuildDescriptionLocator.find(model: model, logURL: GraphFixtures.cleanDD,
                                                               explicit: nil, snapshotsDir: snapshots))
        XCTAssertEqual(found.basis, "snapshot")
        XCTAssertNil(found.signature)
        let doc = try GraphFixtures.report(model, description: found, topN: 5).document
        XCTAssertEqual(doc.graph.basis, "snapshot")
        XCTAssertEqual(doc.graph.signature, "05e6f8da62523e252c9ce2f537414df7", "filled from the log")
    }

    /// `xcblame build` passes the snapshot it just wrote as `explicit`; a partial one must not hide the
    /// `snapshotsDir/<uuid>/` copy or the live description.
    func testUnloadableExplicitFolderFallsThroughToTheSnapshot() throws {
        let empty = scratch.appendingPathComponent("partial")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        let snapshots = scratch.appendingPathComponent("snapshots")
        try copyDescription(from: GraphFixtures.descriptionDD,
                            to: snapshots.appendingPathComponent("5E3BDB3A-008A-466D-A419-CB4D4E8CED29"),
                            signatureFile: false)
        let model = try GraphFixtures.model(GraphFixtures.cleanDD)
        let found = try XCTUnwrap(BuildDescriptionLocator.find(model: model, logURL: GraphFixtures.cleanDD,
                                                               explicit: empty, snapshotsDir: snapshots))
        XCTAssertEqual(found.basis, "snapshot")
        XCTAssertEqual(found.commands.count, 753)
        XCTAssertTrue(found.notes.first?.contains("did not load") == true, "\(found.notes)")
        XCTAssertTrue(found.notes.contains("snapshot of this log's build"), "\(found.notes)")
        let doc = try GraphFixtures.report(model, description: found, topN: 5).document
        XCTAssertTrue(doc.graph.notes.contains { $0.contains("did not load") }, "\(doc.graph.notes)")

        // Nothing to fall back to: no description.
        XCTAssertNil(BuildDescriptionLocator.find(model: model, logURL: GraphFixtures.cleanDD, explicit: empty,
                                                  snapshotsDir: scratch))
    }

    func testLiveDescriptionMatchedBySignatureThenByCoverage() throws {
        let derived = scratch.appendingPathComponent("DD")
        let logs = derived.appendingPathComponent("Logs/Build")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let log = logs.appendingPathComponent(GraphFixtures.incrementalDD.lastPathComponent)
        try FileManager.default.copyItem(at: GraphFixtures.incrementalDD, to: log)
        let data = derived.appendingPathComponent("Build/Intermediates.noindex/XCBuildData")
        let model = try GraphFixtures.model(log)
        // The incremental log reused its description: no signature line, but the CreateBuildDescription key is it.
        XCTAssertEqual(BuildDescriptionLocator.signature(of: model), "05e6f8da62523e252c9ce2f537414df7")

        try copyDescription(from: GraphFixtures.descriptionDD,
                            to: data.appendingPathComponent("05e6f8da62523e252c9ce2f537414df7.xcbuilddata"),
                            signatureFile: false)
        let bySignature = try XCTUnwrap(BuildDescriptionLocator.find(model: model, logURL: log, explicit: nil,
                                                                     snapshotsDir: scratch))
        XCTAssertEqual(bySignature.basis, "live")
        XCTAssertEqual(bySignature.signature, "05e6f8da62523e252c9ce2f537414df7")
        XCTAssertTrue(bySignature.notes.first?.contains("signature") == true, "\(bySignature.notes)")

        try FileManager.default.moveItem(
            at: data.appendingPathComponent("05e6f8da62523e252c9ce2f537414df7.xcbuilddata"),
            to: data.appendingPathComponent("ffffffffffffffffffffffffffffffff.xcbuilddata"))
        let byCoverage = try XCTUnwrap(BuildDescriptionLocator.find(model: model, logURL: log, explicit: nil,
                                                                    snapshotsDir: nil))
        XCTAssertEqual(byCoverage.basis, "live")
        XCTAssertTrue(byCoverage.notes.first?.contains("key coverage") == true, "\(byCoverage.notes)")
    }

    func testNoDescriptionOutsideDerivedData() throws {
        let model = try GraphFixtures.model(GraphFixtures.cleanDD)
        XCTAssertNil(BuildDescriptionLocator.find(model: model, logURL: GraphFixtures.cleanDD, explicit: nil,
                                                  snapshotsDir: scratch))
    }

    private func copyDescription(from source: URL, to dir: URL, signatureFile: Bool) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        for name in ["manifest.json.gz", "target-graph.txt", "build-request.json"] + (signatureFile ? ["SIGNATURE"] : []) {
            try fm.copyItem(at: source.appendingPathComponent(name), to: dir.appendingPathComponent(name))
        }
    }
}
