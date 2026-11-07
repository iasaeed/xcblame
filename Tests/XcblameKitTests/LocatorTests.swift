import Foundation
import XCTest
@testable import XcblameKit

final class LocatorTests: XCTestCase {
    private func dir(_ name: String) -> URL { LaneBFixtures.root.appendingPathComponent(name) }

    func testManifestParsingOnAllFixtures() throws {
        let cli26 = try ManifestReader.read(url: dir("cli-xcode26/LogStoreManifest.plist"))
        XCTAssertEqual(cli26.logFormatVersion, 11)
        XCTAssertEqual(cli26.entries.count, 3)
        let first = try XCTUnwrap(cli26.entries.first { $0.fileName == "20E8B73D-96FE-4232-8A33-311BFD02F961.xcactivitylog" })
        XCTAssertEqual(first.className, "IDECommandLineBuildLog")
        XCTAssertEqual(first.domainType, Locator.buildLogDomain)
        XCTAssertEqual(first.schemeName, "AcmeApp")
        XCTAssertEqual(first.status, "W")
        XCTAssertEqual(first.warningCount, 1)
        XCTAssertEqual(first.errorCount, 0)
        // 815073642.75 on the 2001 epoch
        XCTAssertEqual(try XCTUnwrap(first.started), 815_073_642.75363898 + 978_307_200, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(first.stopped) - XCTUnwrap(first.started), 18.14, accuracy: 0.01)

        let cli27 = try ManifestReader.read(url: dir("cli-xcode27.1b/LogStoreManifest.plist"))
        XCTAssertEqual(cli27.logFormatVersion, 13)
        XCTAssertEqual(cli27.entries.count, 3)

        let ide = try ManifestReader.read(url: dir("ide-xcode26/LogStoreManifest.plist"))
        XCTAssertEqual(ide.logFormatVersion, 11)
        XCTAssertEqual(ide.entries.count, 4)
        XCTAssertTrue(ide.entries.allSatisfy { $0.domainType == "Xcode.IDEActivityLogDomainType.PackageLog" })
    }

    func testCLIFixtureListsThreeCandidatesNewestFirst() throws {
        for name in ["cli-xcode26", "cli-xcode27.1b"] {
            let listing = Locator.candidates(in: dir(name))
            XCTAssertEqual(listing.candidates.count, 3, name)
            XCTAssertNil(listing.emptyReason)
            let times = listing.candidates.compactMap(\.entry.started)
            XCTAssertEqual(times.count, 3)
            XCTAssertEqual(times, times.sorted(by: >), "newest first in \(name)")
            XCTAssertEqual(try Locator.select(listing).url, listing.candidates[0].url)
            XCTAssertEqual(try Locator.select(listing, index: 2).url, listing.candidates[2].url)
            XCTAssertThrowsError(try Locator.select(listing, index: 3))
        }
    }

    func testConfirmHookPicksNewestConfirmed() throws {
        let listing = Locator.candidates(in: dir("cli-xcode26"))
        let second = listing.candidates[1].url
        XCTAssertEqual(try Locator.select(listing, confirm: { $0 == second }).url, second)
        XCTAssertThrowsError(try Locator.select(listing, confirm: { _ in false })) {
            XCTAssertEqual($0 as? LocatorError, .noConfirmedLog(checked: 3))
        }
        // An explicit index bypasses confirmation.
        XCTAssertEqual(try Locator.select(listing, index: 0, confirm: { _ in false }).url, listing.candidates[0].url)
    }

    func testIDEPackageLogsAreNotBuildCandidates() throws {
        let listing = Locator.candidates(in: dir("ide-xcode26"))
        XCTAssertTrue(listing.candidates.isEmpty)
        XCTAssertEqual(listing.rejected.count, 4)
        let reason = try XCTUnwrap(listing.emptyReason)
        XCTAssertTrue(reason.contains("PackageLog"), reason)
        XCTAssertThrowsError(try Locator.select(listing)) { error in
            let text = error.localizedDescription
            XCTAssertTrue(text.contains("PackageLog"), text)
            XCTAssertTrue(text.contains(
                "xcodebuild may not write an activity log without -resultBundlePath; run it through `xcblame build -- ...`"))
        }
    }

    func testFamilyTableExcludesFakeClassName() throws {
        XCTAssertEqual(Locator.buildLogClassFamily,
                       ["IDECommandLineBuildLog", "IDEActivityLogSection", "IDEActivityLogMajorGroupSection"])
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("xcblame-loc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        func entry(_ id: String, _ cls: String, _ domain: String) -> String {
            """
            <key>\(id)</key><dict><key>className</key><string>\(cls)</string><key>domainType</key><string>\(domain)</string>
            <key>fileName</key><string>\(id).xcactivitylog</string><key>timeStartedRecording</key><real>1</real></dict>
            """
        }
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>logFormatVersion</key><integer>11</integer>
        <key>logs</key><dict>\(entry("A", "IDEActivityLogMajorGroupSection", Locator.buildLogDomain))
        \(entry("B", "IDEFakeLogClass", Locator.buildLogDomain))</dict></dict></plist>
        """
        try plist.write(to: tmp.appendingPathComponent(ManifestReader.fileName), atomically: true, encoding: .utf8)
        for id in ["A", "B"] { FileManager.default.createFile(atPath: tmp.appendingPathComponent("\(id).xcactivitylog").path, contents: Data()) }
        let listing = Locator.candidates(in: tmp)
        XCTAssertEqual(listing.candidates.map(\.entry.fileName), ["A.xcactivitylog"])
        XCTAssertEqual(listing.rejected.map(\.fileName), ["B.xcactivitylog"])
        XCTAssertTrue(listing.rejected[0].reason.contains("IDEFakeLogClass"))
    }

    func testManifestFileNameMustStayInsideLogsBuild() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("xcblame-mf-\(UUID().uuidString)")
        let build = dir.appendingPathComponent("Logs/Build")
        try FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("x".utf8).write(to: dir.appendingPathComponent("outside.xcactivitylog"))
        let entry: [String: Any] = ["fileName": "../outside.xcactivitylog", "className": "IDECommandLineBuildLog",
                                    "domainType": Locator.buildLogDomain]
        try NSDictionary(dictionary: ["logFormatVersion": 11, "logs": ["A": entry]])
            .write(to: build.appendingPathComponent(ManifestReader.fileName))
        let listing = Locator.candidates(in: build)
        XCTAssertTrue(listing.candidates.isEmpty)
        XCTAssertEqual(listing.rejected.map(\.reason), ["fileName is not a plain file name"])
    }

    func testMissingDirectoryHasReason() {
        let listing = Locator.candidates(in: URL(fileURLWithPath: "/nonexistent/Logs/Build"))
        XCTAssertTrue(listing.candidates.isEmpty)
        XCTAssertEqual(listing.emptyReason, "/nonexistent/Logs/Build does not exist")
    }

    // MARK: DerivedData discovery

    private func makeDerivedData(workspace: String) throws -> (root: URL, buildDir: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("xcblame-dd-\(UUID().uuidString)")
        let project = root.appendingPathComponent("App-abcdefghijklmnopqrstuvwxyzab")
        let build = project.appendingPathComponent("Logs/Build")
        try FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: dir("cli-xcode26/LogStoreManifest.plist"),
                                         to: build.appendingPathComponent(ManifestReader.fileName))
        try NSDictionary(dictionary: ["WorkspacePath": workspace]).write(to: project.appendingPathComponent("info.plist"))
        // A decoy for another workspace.
        let other = root.appendingPathComponent("Other-zzzzzzzzzzzzzzzzzzzzzzzzzzzz")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try NSDictionary(dictionary: ["WorkspacePath": "/elsewhere/Other.xcodeproj"])
            .write(to: other.appendingPathComponent("info.plist"))
        return (root, build)
    }

    func testDerivedDataMatchByWorkspacePath() throws {
        let (root, build) = try makeDerivedData(workspace: "/work/App.xcodeproj")
        defer { try? FileManager.default.removeItem(at: root) }
        let hit = DerivedDataLocator(explicitPath: root, workspace: URL(fileURLWithPath: "/work/App.xcodeproj"),
                                     home: root, customLocation: { nil }).locate()
        XCTAssertEqual(hit.buildDir?.standardizedFileURL.path, build.standardizedFileURL.path)
        XCTAssertEqual(hit.source, "explicit")

        let miss = DerivedDataLocator(explicitPath: root, workspace: URL(fileURLWithPath: "/work/Nope.xcodeproj"),
                                      home: root, customLocation: { nil }).locate()
        XCTAssertNil(miss.buildDir)
        XCTAssertTrue(miss.failureDescription.contains(root.path), miss.failureDescription)
        XCTAssertTrue(miss.failureDescription.contains("none has WorkspacePath /work/Nope.xcodeproj"))
        // explicit + default (under the fake home) were both searched and listed
        XCTAssertEqual(miss.searched.map(\.source), ["explicit", "default"])
    }

    func testDerivedDataCustomLocationAndExplicitBuildDir() throws {
        let (root, build) = try makeDerivedData(workspace: "/work/App.xcodeproj")
        defer { try? FileManager.default.removeItem(at: root) }
        let viaDefaults = DerivedDataLocator(workspace: URL(fileURLWithPath: "/work/App.xcodeproj"),
                                             home: URL(fileURLWithPath: "/nonexistent-home"),
                                             customLocation: { root.path }).locate()
        XCTAssertEqual(viaDefaults.source, "defaults")
        XCTAssertEqual(viaDefaults.buildDir?.standardizedFileURL.path, build.standardizedFileURL.path)

        let direct = DerivedDataLocator(derivedDataPathArgument: build, home: root, customLocation: { nil }).locate()
        XCTAssertEqual(direct.buildDir, build)
        XCTAssertEqual(direct.source, "derivedDataPath")
    }

    /// `analyze <project folder>`: the project is matched by WorkspacePath under a fake home's default DerivedData
    /// root (the real ~/Library is never read).
    func testProjectFolderResolvesThroughWorkspacePath() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("xcblame-proj-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let projectDir = base.appendingPathComponent("work/App")
        let xcodeproj = projectDir.appendingPathComponent("App.xcodeproj")
        try FileManager.default.createDirectory(at: xcodeproj, withIntermediateDirectories: true)
        let home = base.appendingPathComponent("home")
        let ddRoot = home.appendingPathComponent("Library/Developer/Xcode/DerivedData")
        try FileManager.default.createDirectory(at: ddRoot, withIntermediateDirectories: true)
        let (dd, build) = try makeDerivedData(workspace: xcodeproj.path)
        defer { try? FileManager.default.removeItem(at: dd) }
        for child in try FileManager.default.contentsOfDirectory(atPath: dd.path) {
            try FileManager.default.moveItem(at: dd.appendingPathComponent(child), to: ddRoot.appendingPathComponent(child))
        }
        let movedBuild = ddRoot.appendingPathComponent(build.deletingLastPathComponent().deletingLastPathComponent()
            .lastPathComponent).appendingPathComponent("Logs/Build")

        let hit = try XCTUnwrap(DerivedDataLocator.locateProject(in: projectDir, home: home, customLocation: { nil }))
        XCTAssertEqual(hit.source, "default")
        XCTAssertEqual(hit.buildDir?.standardizedFileURL.path, movedBuild.standardizedFileURL.path)
        let listing = Locator.candidates(in: try XCTUnwrap(hit.buildDir))
        XCTAssertFalse(listing.candidates.isEmpty && listing.rejected.isEmpty, "the manifest was read")

        let otherDir = base.appendingPathComponent("work/Other")
        try FileManager.default.createDirectory(at: otherDir.appendingPathComponent("Other.xcworkspace"),
                                                withIntermediateDirectories: true)
        let miss = try XCTUnwrap(DerivedDataLocator.locateProject(in: otherDir, home: home, customLocation: { nil }))
        XCTAssertNil(miss.buildDir)
        XCTAssertTrue(miss.failureDescription.contains(ddRoot.path), miss.failureDescription)
        XCTAssertNil(DerivedDataLocator.locateProject(in: home, home: home, customLocation: { nil }),
                     "no workspace or project in the folder")
    }

    func testWorkspaceSettingsRelativePath() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("xcblame-ws-\(UUID().uuidString)")
        let workspace = base.appendingPathComponent("App.xcworkspace")
        let shared = workspace.appendingPathComponent("xcshareddata")
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try NSDictionary(dictionary: ["DerivedDataLocationStyle": "WorkspaceRelativePath",
                                      "DerivedDataCustomLocation": "dd"])
            .write(to: shared.appendingPathComponent("WorkspaceSettings.xcsettings"))
        let locations = DerivedDataLocator(workspace: workspace).workspaceSettingsLocations(workspace)
        XCTAssertEqual(locations.map { $0.standardizedFileURL.path }, [base.appendingPathComponent("dd").standardizedFileURL.path])
    }

    // MARK: Integrity

    func testWaitForStable() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("xcblame-int-\(UUID().uuidString)")
        try Data(repeating: 1, count: 100).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let start = Date()
        XCTAssertEqual(LogIntegrity.waitForStable(file, timeout: 5), .stable(size: 100))
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(start), 0.5)
        XCTAssertEqual(LogIntegrity.waitForStable(file, timeout: 1.5, verify: { _ in false }), .unverified(size: 100))
        XCTAssertEqual(LogIntegrity.waitForStable(file.appendingPathExtension("gone"), timeout: 1), .missing)
    }

    func testWaitForStableSeesGrowth() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("xcblame-grow-\(UUID().uuidString)")
        try Data(count: 1).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let writer = Thread {
            for _ in 0..<30 {
                if let handle = try? FileHandle(forWritingTo: file) {
                    _ = try? handle.seekToEnd()
                    try? handle.write(contentsOf: Data(count: 10))
                    try? handle.close()
                }
                Thread.sleep(forTimeInterval: 0.1)
            }
        }
        writer.start()
        XCTAssertEqual(LogIntegrity.waitForStable(file, timeout: 1.5), .stillGrowing)
    }
}
