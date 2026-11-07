import XCTest
@testable import XcblameKit

/// The oracle's zero-writes guard, its cache outside the repository, and package reuse without network
/// (code review v0.3 majors 4, 5; verification: nested local packages, cloned instead of reused checkouts).
final class OracleCacheTests: XCTestCase {
    /// A scratch copy of AcmeApp whose local package has a nested local package (not in the project model).
    private func acmeCopy() throws -> (root: URL, model: ProjectModel) {
        let root = SettingsFixtures.scratch("oracle-acme", self).appendingPathComponent("AcmeApp")
        try FileManager.default.createDirectory(at: root.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: SettingsFixtures.acme, to: root)
        var model = SettingsFixtures.acmeModel()
        model.root = root
        let xcodeproj = root.appendingPathComponent("AcmeApp.xcodeproj")
        model.container = .xcodeproj(xcodeproj)
        model.projects[0].path = xcodeproj
        model.packages = model.packages.map { package in
            var package = package
            if package.path != nil { package.path = root.appendingPathComponent("Packages/AcmeShared") }
            return package
        }
        return (root, model)
    }

    // MARK: A. Write guard

    func testWriteGuardRemovesEmptyFoldersCreatedInANestedLocalPackage() throws {
        let (root, model) = try acmeCopy()
        let nested = root.appendingPathComponent("Packages/AcmeShared/Packages/Nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("// swift-tools-version:5.9\nimport PackageDescription\nlet package = Package(name: \"Nested\")\n".utf8)
            .write(to: nested.appendingPathComponent("Package.swift"))
        let before = SettingsFixtures.treeHash(root)
        let guardian = WriteGuard(roots: [model.root] + XcodebuildSettings.localPackageDirs(model))
        // What xcodebuild leaves behind: `.swiftpm/xcode` in the nested package (not in the model) and in AcmeShared.
        for dir in [nested, root.appendingPathComponent("Packages/AcmeShared")] {
            try FileManager.default.createDirectory(at: dir.appendingPathComponent(".swiftpm/xcode"),
                                                    withIntermediateDirectories: true)
        }
        let restored = guardian.restore()
        XCTAssertEqual(restored.removed.map { URL(fileURLWithPath: $0).deletingLastPathComponent().lastPathComponent }.sorted(),
                       ["AcmeShared", "Nested"])
        XCTAssertEqual(restored.notes, [])
        XCTAssertEqual(SettingsFixtures.treeHash(root), before, "removed, and the parents' mtimes restored")

        // A new folder holding a file is never deleted, only reported.
        let second = WriteGuard(roots: [model.root])
        let kept = nested.appendingPathComponent(".swiftpm/configuration")
        try FileManager.default.createDirectory(at: kept, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: kept.appendingPathComponent("Package.resolved"))
        let report = second.restore()
        XCTAssertEqual(report.removed, [])
        XCTAssertEqual(report.notes, ["xcodebuild wrote \(nested.appendingPathComponent(".swiftpm").path) (left in place)"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: kept.appendingPathComponent("Package.resolved").path))
    }

    func testWriteGuardSkipsGitAndBuildFolders() throws {
        let (root, _) = try acmeCopy()
        let git = root.appendingPathComponent(".git")
        try FileManager.default.createDirectory(at: git, withIntermediateDirectories: true)
        let guardian = WriteGuard(roots: [root])
        try FileManager.default.createDirectory(at: git.appendingPathComponent("objects/aa"), withIntermediateDirectories: true)
        XCTAssertEqual(guardian.restore().removed, [], ".git is not watched")
        XCTAssertTrue(FileManager.default.fileExists(atPath: git.appendingPathComponent("objects/aa").path))
    }

    // MARK: B. Cache outside the repository

    func testOracleScratchLivesInTheCacheHomeAndOnlyJSONInTheStateFolder() throws {
        guard SettingsFixtures.xcodebuildAvailable() else { throw XCTSkip("xcodebuild not available") }
        let root = SettingsFixtures.scratch("oracle-prec", self).appendingPathComponent("Precedence")
        try FileManager.default.createDirectory(at: root.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: SettingsFixtures.precedence, to: root)
        let model = SettingsFixtures.precedenceModel(root: root)
        let state = root.appendingPathComponent(".xcblame/cache/settings")
        let home = SettingsFixtures.scratch("oracle-home", self)
        let all = SettingsOracle.effectiveAll(project: model, configurations: ["Debug"], scheme: nil, offline: false,
                                              cacheDir: state, cacheHome: home)
        XCTAssertEqual(all["Debug"]?.source, .xcodebuild, "\(all["Debug"]?.notes ?? [])")
        let scratch = OracleCache.directory(for: model.container.url, home: home)
        XCTAssertTrue(scratch.path.hasPrefix(home.appendingPathComponent("oracle/").path))
        XCTAssertEqual(scratch.lastPathComponent.count, 16)
        XCTAssertTrue(FileManager.default.fileExists(atPath: scratch.appendingPathComponent("Settings.xcworkspace").path))
        let inState = try FileManager.default.contentsOfDirectory(atPath: state.path)
        XCTAssertFalse(inState.isEmpty)
        XCTAssertTrue(inState.allSatisfy { $0.hasSuffix(".json") }, "only the settings JSON in the repo: \(inState)")
        XCTAssertGreaterThan(OracleCache.size(of: scratch), 0)
    }

    func testOracleCacheHomeOverrideFallbackAndPrune() throws {
        let custom = SettingsFixtures.scratch("oracle-custom", self)
        XCTAssertEqual(OracleCache.home(environment: ["XCBLAME_CACHE_DIR": custom.path]).path, custom.standardizedFileURL.path)
        XCTAssertTrue(OracleCache.home(environment: [:]).path.hasSuffix("/Library/Caches/xcblame")
            || OracleCache.home(environment: [:]).path.hasSuffix("/xcblame"))
        let old = OracleCache.directory(for: URL(fileURLWithPath: "/a/A.xcodeproj"), home: custom)
        let fresh = OracleCache.directory(for: URL(fileURLWithPath: "/b/B.xcodeproj"), home: custom)
        for dir in [old, fresh] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            OracleCache.touch(dir)  // the oracle's marker: prune never deletes anything else
        }
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-31 * 86_400)], ofItemAtPath: old.path)
        XCTAssertEqual(OracleCache.prune(home: custom, olderThanDays: OracleCache.keepDays), 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path))
        XCTAssertEqual(OracleCache.prune(home: custom, olderThanDays: nil), 1, "--oracle-cache removes everything")
    }

    func testStateGitignoreListsCacheAndUpgradesEarlierVersions() throws {
        let dir = SettingsFixtures.scratch("oracle-ignore", self)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent(".gitignore")
        try Data("history/\nsnapshots/\nreports/\nresults/\nlogs/\n".utf8).write(to: file)
        ensureStateIgnore(in: dir)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "history/\nsnapshots/\nreports/\nresults/\nlogs/\ncache/\ntmp/\nplans/\nbackup/\n")
    }

    // MARK: C. analyze never resolves

    func testWithoutCheckoutsAnalyzeGoesOfflineAtOnce() throws {
        let (_, model) = try acmeCopy()
        let start = Date()
        let all = SettingsOracle.effectiveAll(project: model, configurations: ["Debug", "Release"], scheme: nil,
                                              offline: false, cacheDir: SettingsFixtures.scratch("oracle-c", self),
                                              timeout: SettingsOracle.analyzeTimeout, resolvePackages: false,
                                              cacheHome: SettingsFixtures.scratch("oracle-c-home", self))
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
        for configuration in ["Debug", "Release"] {
            XCTAssertEqual(all[configuration]?.source, .offlineResolver)
            XCTAssertTrue(all[configuration]?.notes.first?.contains("analyze never resolves packages") == true,
                          "\(all[configuration]?.notes ?? [])")
        }
    }

    // MARK: D. Reusing the project's checkouts

    /// A project-local DerivedData (`-derivedDataPath build/dd`) naming the container, with checkouts at the pinned
    /// revisions: found, and the oracle cache never gets a SourcePackages folder (no clone).
    func testProjectLocalDerivedDataCheckoutsAreReusedAndNeverCloned() throws {
        let (root, model) = try acmeCopy()
        let derived = root.appendingPathComponent("build/dd")
        let packages = derived.appendingPathComponent("SourcePackages")
        let pins = try XCTUnwrap(XcodebuildSettings.pins(model))
        XCTAssertEqual(pins["swift-collections"], "671108c96644956dddcd89dd59c203dcdb36cec7")
        for name in pins.keys {
            try FileManager.default.createDirectory(at: packages.appendingPathComponent("checkouts/\(name)"),
                                                    withIntermediateDirectories: true)
        }
        try writeState(packages, pins: pins)
        let info = NSDictionary(dictionary: ["WorkspacePath": model.container.url.path])
        try info.write(to: derived.appendingPathComponent("info.plist"))
        XCTAssertEqual(XcodebuildSettings.sourcePackages(model) { _ in nil }?.standardizedFileURL.path,
                       packages.standardizedFileURL.path, "found by WorkspacePath under the project root")
        XCTAssertEqual(XcodebuildSettings.pinsMatch(model, checkouts: packages), true)

        // Without the plist, the pins decide (Flutter's build/ios has no info.plist).
        try FileManager.default.removeItem(at: derived.appendingPathComponent("info.plist"))
        XCTAssertEqual(XcodebuildSettings.sourcePackages(model) { _ in nil }?.standardizedFileURL.path,
                       packages.standardizedFileURL.path)

        // Xcode's default DerivedData root, matched by WorkspacePath without build logs.
        let home = SettingsFixtures.scratch("oracle-d-home", self)
        let xcodeDD = home.appendingPathComponent("Library/Developer/Xcode/DerivedData/AcmeApp-abc")
        try FileManager.default.createDirectory(at: xcodeDD.appendingPathComponent("SourcePackages/checkouts/swift-syntax"),
                                                withIntermediateDirectories: true)
        try info.write(to: xcodeDD.appendingPathComponent("info.plist"))
        XCTAssertNil(DerivedDataLocator(workspace: model.container.url, home: home, customLocation: { nil }).locate().derivedData,
                     "the build-log locator needs Logs/Build")

        // The oracle runs a fake xcodebuild (no network, no ~/Library/Caches/org.swift.swiftpm): the checkouts above are
        // placeholders, which a real xcodebuild would try to re-clone from GitHub. The fake records what it was given.
        guard SettingsFixtures.xcodebuildAvailable() else { throw XCTSkip("xcodebuild not available") }
        for name in pins.keys {
            try Data("checkout\n".utf8).write(to: packages.appendingPathComponent("checkouts/\(name)/marker.txt"))
        }
        let before = SettingsFixtures.treeHash(packages)
        let cacheHome = SettingsFixtures.scratch("oracle-d-cache", self)
        let fake = try fakeXcodebuild(model: model)
        let all = SettingsOracle.effectiveAll(project: model, configurations: ["Debug"], scheme: nil, offline: false,
                                              cacheDir: SettingsFixtures.scratch("oracle-d-state", self),
                                              timeout: SettingsOracle.analyzeTimeout, cacheHome: cacheHome,
                                              xcodebuild: fake.script.path)
        // doctor: never passed to xcodebuild in place; an APFS clone of them in the oracle entry is (no network
        // clone). (analyze never clones: `testAnalyzeNeverClonesTheProjectsCheckouts`.)
        let scratch = OracleCache.directory(for: model.container.url, home: cacheHome)
        let clone = scratch.appendingPathComponent("SourcePackages")
        let notes = "\(all["Debug"]?.notes ?? [])"
        XCTAssertEqual(all["Debug"]?.source, .xcodebuild, notes)
        XCTAssertEqual(XcodebuildSettings.stateRevisions(clone), pins, notes)
        for name in pins.keys {
            XCTAssertTrue(FileManager.default.fileExists(atPath: clone.appendingPathComponent("checkouts/\(name)/marker.txt").path),
                          "\(name) cloned with its contents")
        }
        let argv = (try? String(contentsOf: fake.log, encoding: .utf8)) ?? ""
        XCTAssertTrue(argv.contains("-clonedSourcePackagesDirPath \(clone.path) "), "xcodebuild got the clone: \(argv)")
        XCTAssertFalse(argv.contains(packages.path), "xcodebuild never got the project's own folder: \(argv)")
        XCTAssertTrue(argv.contains("-skipPackageUpdates") && argv.contains("-disableAutomaticPackageResolution"), argv)
        XCTAssertEqual(SettingsFixtures.treeHash(packages), before, "the project's checkouts were not written")
        XCTAssertFalse(all["Debug"]?.notes.contains { $0.contains("analyze never resolves") } ?? true,
                       "the project's checkouts were used")
        XCTAssertTrue(all["Debug"]?.notes.contains { $0.contains("package checkouts cloned from") } ?? false, notes)
    }

    /// A stand-in for `/usr/bin/xcodebuild -showBuildSettings -json`: logs its arguments and lists every target of the
    /// model with minimal settings. The oracle never reaches the network, and no real package checkout is needed.
    private func fakeXcodebuild(model: ProjectModel) throws -> (script: URL, log: URL) {
        let dir = SettingsFixtures.scratch("oracle-fake-xcodebuild", self)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let log = dir.appendingPathComponent("argv.log")
        let script = dir.appendingPathComponent("xcodebuild")
        let entries = model.projects.flatMap(\.targets).map {
            "{\"target\":\"\($0.name)\",\"action\":\"build\",\"buildSettings\":{\"PROJECT_NAME\":\"\(model.projects[0].name)\"}}"
        }
        let body = "#!/bin/sh\necho \"$@ \" >> '\(log.path)'\ncat <<'JSON'\n[\(entries.joined(separator: ","))]\nJSON\n"
        try Data(body.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return (script, log)
    }

    /// Pins changed since Xcode resolved: the project's checkouts are not used (never updated), and analyze goes
    /// offline with a note instead of resolving.
    func testChangedPinsNeverTouchTheProjectsCheckouts() throws {
        let (root, model) = try acmeCopy()
        let packages = root.appendingPathComponent("build/dd/SourcePackages")
        var pins = try XCTUnwrap(XcodebuildSettings.pins(model))
        for name in pins.keys {
            try FileManager.default.createDirectory(at: packages.appendingPathComponent("checkouts/\(name)"),
                                                    withIntermediateDirectories: true)
        }
        pins["swift-collections"] = "0000000000000000000000000000000000000000"
        try writeState(packages, pins: pins)
        try NSDictionary(dictionary: ["WorkspacePath": model.container.url.path])
            .write(to: root.appendingPathComponent("build/dd/info.plist"))
        XCTAssertEqual(XcodebuildSettings.pinsMatch(model, checkouts: packages), false)
        let before = SettingsFixtures.treeHash(packages)
        let all = SettingsOracle.effectiveAll(project: model, configurations: ["Debug"], scheme: nil, offline: false,
                                              cacheDir: SettingsFixtures.scratch("oracle-p", self),
                                              timeout: SettingsOracle.analyzeTimeout, resolvePackages: false,
                                              cacheHome: SettingsFixtures.scratch("oracle-p-home", self))
        XCTAssertEqual(all["Debug"]?.source, .offlineResolver)
        XCTAssertTrue(all["Debug"]?.notes.first?.contains("do not match Package.resolved") == true, "\(all["Debug"]?.notes ?? [])")
        XCTAssertEqual(SettingsFixtures.treeHash(packages), before)
    }

    private func writeState(_ packages: URL, pins: [String: String]) throws {
        let dependencies = pins.map { ["packageRef": ["identity": $0.key], "state": ["checkoutState": ["revision": $0.value]]] }
        let data = try JSONSerialization.data(withJSONObject: ["object": ["dependencies": dependencies], "version": 6])
        try data.write(to: packages.appendingPathComponent("workspace-state.json"))
    }
}

/// Re-check R1, R4, R5, R7, R8 (code review v0.3, second pass).
final class OracleRecheckTests: XCTestCase {
    func testCappedSnapshotNeverDeletes() throws {
        let root = SettingsFixtures.scratch("recheck-guard", self)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("a"), withIntermediateDirectories: true)
        var guardian = WriteGuard(roots: [root])
        XCTAssertFalse(guardian.truncated)
        guardian.forceTruncatedForTesting()
        try FileManager.default.createDirectory(at: root.appendingPathComponent("a/.swiftpm/xcode"), withIntermediateDirectories: true)
        let restored = guardian.restore()
        XCTAssertEqual(restored.removed, [])
        XCTAssertTrue(restored.notes.first?.contains("nothing was removed") == true, "\(restored.notes)")
        XCTAssertTrue(restored.notes.contains { $0.hasSuffix("/a/.swiftpm (left in place)") }, "\(restored.notes)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("a/.swiftpm/xcode").path))
    }

    func testReusedSourcePackagesInsideASkippedFolderAreWatched() throws {
        let root = SettingsFixtures.scratch("recheck-sp", self)
        let packages = root.appendingPathComponent("DerivedData/SourcePackages")
        try FileManager.default.createDirectory(at: packages.appendingPathComponent("checkouts"), withIntermediateDirectories: true)
        let guardian = WriteGuard(roots: [root, packages])
        try FileManager.default.createDirectory(at: packages.appendingPathComponent("artifacts/x"), withIntermediateDirectories: true)
        XCTAssertEqual(guardian.restore().removed, [packages.appendingPathComponent("artifacts").standardizedFileURL.path])
    }

    func testTimeoutKillsTheWholeProcessTree() throws {
        let dir = SettingsFixtures.scratch("recheck-kill", self)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let pidFile = dir.appendingPathComponent("child.pid")
        let output = try XCTUnwrap(runProcess(["/bin/sh", "-c", "sleep 30 & echo $! > '\(pidFile.path)'; wait"], timeout: 0.5))
        XCTAssertTrue(output.timedOut)
        let pid = try XCTUnwrap(pid_t(String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        var alive = true
        for _ in 0..<50 where alive {
            alive = kill(pid, 0) == 0
            if alive { usleep(20_000) }
        }
        XCTAssertFalse(alive, "the sleeping child was killed with its parent")
    }

    /// Without `Package.resolved` nothing proves the checkouts' revisions: they are not reused.
    func testCheckoutsWithoutPackageResolvedAreNotReused() throws {
        let root = SettingsFixtures.scratch("recheck-pins", self).appendingPathComponent("AcmeApp")
        try FileManager.default.createDirectory(at: root.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: SettingsFixtures.acme, to: root)
        try FileManager.default.removeItem(at: root.appendingPathComponent("AcmeApp.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"))
        var model = SettingsFixtures.acmeModel()
        model.root = root
        model.container = .xcodeproj(root.appendingPathComponent("AcmeApp.xcodeproj"))
        model.projects[0].path = root.appendingPathComponent("AcmeApp.xcodeproj")
        let packages = root.appendingPathComponent("build/dd/SourcePackages")
        try FileManager.default.createDirectory(at: packages.appendingPathComponent("checkouts/swift-collections"),
                                                withIntermediateDirectories: true)
        try NSDictionary(dictionary: ["WorkspacePath": model.container.url.path])
            .write(to: root.appendingPathComponent("build/dd/info.plist"))
        XCTAssertNotNil(XcodebuildSettings.sourcePackages(model) { _ in nil })
        XCTAssertNil(XcodebuildSettings.pinsMatch(model, checkouts: packages))
        let all = SettingsOracle.effectiveAll(project: model, configurations: ["Debug"], scheme: nil, offline: false,
                                              cacheDir: SettingsFixtures.scratch("recheck-pins-state", self),
                                              timeout: 5, resolvePackages: false,
                                              cacheHome: SettingsFixtures.scratch("recheck-pins-home", self))
        XCTAssertTrue(all["Debug"]?.notes.first?.contains("cannot be checked (no Package.resolved): not used") == true,
                      "\(all["Debug"]?.notes ?? [])")
    }

    func testPruneOnlyRemovesOracleEntries() throws {
        let home = SettingsFixtures.scratch("recheck-prune", self)
        let oracle = home.appendingPathComponent("oracle")
        let marked = oracle.appendingPathComponent("0123456789abcdef")
        let workspace = oracle.appendingPathComponent("fedcba9876543210/Settings.xcworkspace")
        let foreign = oracle.appendingPathComponent("my-notes")
        for dir in [marked, workspace, foreign] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        OracleCache.touch(marked)
        XCTAssertTrue(FileManager.default.fileExists(atPath: marked.appendingPathComponent(".xcblame-oracle").path))
        XCTAssertEqual(OracleCache.prune(home: home, olderThanDays: nil), 2)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: oracle.path), ["my-notes"])
    }

    func testPodCountCountsRootPodsOnly() throws {
        let dir = SettingsFixtures.scratch("recheck-pods", self)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let lock = dir.appendingPathComponent("Podfile.lock")
        try Data("""
            PODS:
              - Firebase/Analytics (10.0.0):
                - Firebase/Core
              - Firebase/Core (10.0.0)
              - "GoogleUtilities/Environment (7.0.0)"
              - GoogleUtilities/Logger (7.0.0)
              - SnapKit (5.7.1)

            DEPENDENCIES:
              - SnapKit

            """.utf8).write(to: lock)
        XCTAssertEqual(ManifestReaders.podCount(lockfile: lock), 3)
    }
}

/// Second verification: the user's checkouts are cloned, never written; the Flutter sibling DerivedData; the timeout
/// cascade; the 5 GB cap.
final class OracleVerifyTests: XCTestCase {
    private func acmeCopy(at relative: String) throws -> (root: URL, model: ProjectModel) {
        let root = SettingsFixtures.scratch("verify-acme", self).appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: root.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: SettingsFixtures.acme, to: root)
        var model = SettingsFixtures.acmeModel()
        model.root = root
        model.container = .xcodeproj(root.appendingPathComponent("AcmeApp.xcodeproj"))
        model.projects[0].path = root.appendingPathComponent("AcmeApp.xcodeproj")
        model.packages = model.packages.map { package in
            var package = package
            if package.path != nil { package.path = root.appendingPathComponent("Packages/AcmeShared") }
            return package
        }
        return (root, model)
    }

    /// Real checkouts from the test cache when there (cloned, so cheap), else fake ones at the pinned revisions.
    private func checkouts(_ model: ProjectModel, into packages: URL) throws {
        let warm = SettingsFixtures.cacheHome.appendingPathComponent("oracle")
        let real = ((try? FileManager.default.contentsOfDirectory(at: warm, includingPropertiesForKeys: nil)) ?? [])
            .map { $0.appendingPathComponent("SourcePackages") }
            .first { XcodebuildSettings.pinsMatch(model, checkouts: $0) == true }
        try FileManager.default.createDirectory(at: packages.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let real, runProcess(["/bin/cp", "-c", "-R", real.path, packages.path], timeout: 120)?.succeeded == true { return }
        let pins = try XCTUnwrap(XcodebuildSettings.pins(model))
        for name in pins.keys {
            try FileManager.default.createDirectory(at: packages.appendingPathComponent("checkouts/\(name)"), withIntermediateDirectories: true)
        }
        let dependencies = pins.map { ["packageRef": ["identity": $0.key], "state": ["checkoutState": ["revision": $0.value]]] }
        try JSONSerialization.data(withJSONObject: ["object": ["dependencies": dependencies], "version": 6])
            .write(to: packages.appendingPathComponent("workspace-state.json"))
    }

    func testProjectCheckoutsAreClonedAndNeverWritten() throws {
        guard SettingsFixtures.xcodebuildAvailable() else { throw XCTSkip("xcodebuild not available") }
        let (root, model) = try acmeCopy(at: "AcmeApp")
        let derived = root.appendingPathComponent("build/dd")
        let packages = derived.appendingPathComponent("SourcePackages")
        try checkouts(model, into: packages)
        try NSDictionary(dictionary: ["WorkspacePath": model.container.url.path]).write(to: derived.appendingPathComponent("info.plist"))
        let state = packages.appendingPathComponent("workspace-state.json")
        let bytes = try Data(contentsOf: state)
        let mtime = try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: state.path)[.modificationDate] as? Date)
        let before = SettingsFixtures.treeHash(packages)
        let cacheHome = SettingsFixtures.scratch("verify-clone-home", self)
        let all = SettingsOracle.effectiveAll(project: model, configurations: ["Debug", "Release"], scheme: nil, offline: false,
                                              cacheDir: SettingsFixtures.scratch("verify-clone-state", self), timeout: 60,
                                              cacheHome: cacheHome)
        XCTAssertEqual(try Data(contentsOf: state), bytes, "workspace-state.json byte-identical")
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: state.path)[.modificationDate] as? Date, mtime)
        XCTAssertEqual(SettingsFixtures.treeHash(packages), before, "nothing written into the user's checkouts")
        XCTAssertTrue(all["Debug"]?.notes.contains {
            $0.hasPrefix("package checkouts cloned from ") && $0.hasSuffix("/build/dd/SourcePackages")
        } == true || all["Debug"]?.source == .offlineResolver, "\(all["Debug"]?.notes ?? [])")
        let clone = OracleCache.directory(for: model.container.url, home: cacheHome).appendingPathComponent("SourcePackages")
        XCTAssertTrue(XcodebuildSettings.hasPackageCheckouts(clone))
    }

    /// Flutter keeps the iOS DerivedData at `<app>/build/ios`, next to the `<app>/ios` folder that holds the
    /// container, without an `info.plist`: found by its pins.
    /// `analyze` never clones the project's checkouts: without a clone from an earlier doctor it goes offline at once.
    func testAnalyzeNeverClonesTheProjectsCheckouts() throws {
        let (root, model) = try acmeCopy(at: "AcmeApp")
        let derived = root.appendingPathComponent("build/dd")
        try checkouts(model, into: derived.appendingPathComponent("SourcePackages"))
        try NSDictionary(dictionary: ["WorkspacePath": model.container.url.path]).write(to: derived.appendingPathComponent("info.plist"))
        let cacheHome = SettingsFixtures.scratch("verify-noclone-home", self)
        let entry = OracleCache.directory(for: model.container.url, home: cacheHome)
        try FileManager.default.createDirectory(at: entry, withIntermediateDirectories: true)
        OracleCache.touch(entry)
        let start = Date()
        let all = SettingsOracle.effectiveAll(project: model, configurations: ["Debug", "Release"], scheme: nil, offline: false,
                                              cacheDir: SettingsFixtures.scratch("verify-noclone-state", self),
                                              timeout: SettingsOracle.analyzeTimeout, resolvePackages: false,
                                              cacheHome: cacheHome, totalTimeout: SettingsOracle.analyzeTimeout)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: entry.appendingPathComponent("SourcePackages").path), "no clone")
        XCTAssertEqual(all["Debug"]?.source, .offlineResolver)
        XCTAssertTrue(all["Debug"]?.notes.first?.contains("analyze never resolves packages") == true, "\(all["Debug"]?.notes ?? [])")
    }

    func testFlutterSiblingBuildFolderIsFound() throws {
        let (root, model) = try acmeCopy(at: "app/ios")
        let packages = root.deletingLastPathComponent().appendingPathComponent("build/ios/SourcePackages")
        try checkouts(model, into: packages)
        XCTAssertEqual(XcodebuildSettings.sourcePackages(model) { _ in nil }?.standardizedFileURL.path,
                       packages.standardizedFileURL.path)
    }

    /// A cold resolve that times out is not repeated by every other configuration.
    func testFirstConfigurationTimeoutSkipsTheOthers() throws {
        guard SettingsFixtures.xcodebuildAvailable() else { throw XCTSkip("xcodebuild not available") }
        let (_, model) = try acmeCopy(at: "AcmeApp")
        let start = Date()
        let all = SettingsOracle.effectiveAll(project: model, configurations: ["Debug", "Release", "Profile"], scheme: nil,
                                              offline: false, cacheDir: SettingsFixtures.scratch("verify-to-state", self),
                                              timeout: 0.5, cacheHome: SettingsFixtures.scratch("verify-to-home", self))
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
        for configuration in ["Release", "Profile"] {
            XCTAssertTrue(all[configuration]?.notes.contains("package resolution failed for Debug; the other configurations were not run") == true,
                          "\(all[configuration]?.notes ?? [])")
        }
    }

    func testPruneCapsTheOracleHomeLeastRecentlyUsedFirst() throws {
        let home = SettingsFixtures.scratch("verify-cap", self)
        var dirs: [URL] = []
        for (i, key) in ["aaaaaaaaaaaaaaaa", "bbbbbbbbbbbbbbbb", "cccccccccccccccc"].enumerated() {
            let dir = home.appendingPathComponent("oracle/\(key)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data(count: 64 * 1024).write(to: dir.appendingPathComponent("blob"))
            OracleCache.touch(dir)
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(Double(i - 3) * 60)],
                                                  ofItemAtPath: dir.path)
            dirs.append(dir)
        }
        XCTAssertEqual(OracleCache.entries(home: home).map(\.url.lastPathComponent), dirs.map(\.lastPathComponent))
        XCTAssertEqual(OracleCache.prune(home: home, olderThanDays: OracleCache.keepDays, maxBytes: 150 * 1024), 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dirs[0].path), "the least recently used entry went")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dirs[2].path))
    }
}
