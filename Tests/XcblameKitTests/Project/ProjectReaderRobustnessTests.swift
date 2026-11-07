import XCTest
@testable import XcblameKit

/// Reader edge cases built in a scratch folder from copies of the fixtures (fixtures themselves stay untouched).
final class ProjectReaderRobustnessTests: XCTestCase {
    private let fixtures = FixtureProjectTests.root
    private let fm = FileManager.default

    private func scratch(_ name: String = "") throws -> URL {
        let dir = fm.temporaryDirectory.appendingPathComponent("xcblame-project-\(UUID().uuidString)")
            .appendingPathComponent(name)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        return dir
    }

    /// Copies a fixture folder into `dir` and returns the copy.
    private func copy(_ fixture: String, into dir: URL) throws -> URL {
        let target = dir.appendingPathComponent(fixture)
        try fm.copyItem(at: fixtures.appendingPathComponent(fixture), to: target)
        return target
    }

    private func edit(_ url: URL, _ transform: (String) -> String) throws {
        let text = try String(contentsOf: url, encoding: .utf8)
        let changed = transform(text)
        XCTAssertNotEqual(text, changed, "edit of \(url.lastPathComponent) changed nothing")
        try changed.write(to: url, atomically: true, encoding: .utf8)
    }

    func testCorruptMissingAndXcprojProjectsThrowXcblameErrors() throws {
        let dir = try scratch()
        let corrupt = dir.appendingPathComponent("Corrupt.xcodeproj")
        try fm.createDirectory(at: corrupt, withIntermediateDirectories: true)
        try Data("// !$*UTF8*$!\n{ objects = { AB = {isa = PBXProject; ".utf8).write(to: corrupt.appendingPathComponent("project.pbxproj"))
        XCTAssertThrowsError(try ProjectModel.load(container: corrupt, scheme: nil)) {
            guard case let XcblameError.projectUnreadable(why) = $0 else { return XCTFail("\($0)") }
            XCTAssertTrue(why.contains("not a valid project file"), why)
        }
        try Data("{ objects = {}; }".utf8).write(to: corrupt.appendingPathComponent("project.pbxproj"))
        XCTAssertThrowsError(try ProjectModel.load(container: corrupt, scheme: nil)) {
            guard case let XcblameError.projectUnreadable(why) = $0 else { return XCTFail("\($0)") }
            XCTAssertTrue(why.contains("no PBXProject root object"), why)
        }

        let empty = dir.appendingPathComponent("Empty.xcodeproj")
        try fm.createDirectory(at: empty, withIntermediateDirectories: true)
        XCTAssertThrowsError(try ProjectModel.load(container: empty, scheme: nil)) {
            guard case XcblameError.projectUnreadable = $0 else { return XCTFail("\($0)") }
        }

        let json = dir.appendingPathComponent("Json.xcodeproj")
        try fm.createDirectory(at: json, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: json.appendingPathComponent("project.xcproj"))
        XCTAssertThrowsError(try ProjectModel.load(container: json, scheme: nil)) {
            guard case let XcblameError.notImplemented(what) = $0 else { return XCTFail("\($0)") }
            XCTAssertTrue(what.contains("project.xcproj read lands after MV-4"), what)
        }

        // A workspace survives a corrupt member project with a note.
        let workspace = dir.appendingPathComponent("W.xcworkspace")
        try fm.createDirectory(at: workspace, withIntermediateDirectories: true)
        let legacy = try copy("AcmeLegacy", into: dir)
        try Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <Workspace version = "1.0">
               <FileRef location = "group:Corrupt.xcodeproj"></FileRef>
               <FileRef location = "group:\(legacy.lastPathComponent)/AcmeLegacy.xcodeproj"></FileRef>
            </Workspace>
            """.utf8).write(to: workspace.appendingPathComponent("contents.xcworkspacedata"))
        let model = try ProjectModel.load(container: workspace, scheme: nil)
        XCTAssertEqual(model.projects.map(\.name), ["AcmeLegacy"])
        XCTAssertTrue(model.notes.contains { $0.contains("project Corrupt.xcodeproj not read") }, "\(model.notes)")
    }

    func testUnknownISAIsIgnoredWithANote() throws {
        let legacy = try copy("AcmeLegacy", into: try scratch())
        try edit(legacy.appendingPathComponent("AcmeLegacy.xcodeproj/project.pbxproj")) {
            $0.replacingOccurrences(of: "/* Begin PBXBuildFile section */", with: """
                B1000000000000000000FF01 = {isa = PBXFutureThing; payload = (1, 2); };
                /* Begin PBXBuildFile section */
                """)
        }
        let model = try ProjectModel.load(container: legacy.appendingPathComponent("AcmeLegacy.xcodeproj"), scheme: nil)
        XCTAssertEqual(model.allTargets.map(\.name), ["AcmeLegacy", "AcmeLegacyKit"])
        XCTAssertTrue(model.notes.contains("AcmeLegacy.xcodeproj: ignored 1 object(s) of unknown isa PBXFutureThing"),
                      "\(model.notes)")
    }

    func testPathsWithSpacesUnicodeAndApostrophes() throws {
        let dir = try scratch("Acme's Ünïcode Projects: ✓/Sub Dir")
        let precedence = try copy("Precedence", into: dir)
        let model = try ProjectModel.load(container: precedence.appendingPathComponent("Precedence.xcodeproj"), scheme: nil)
        let xcconfig = try XCTUnwrap(model.projects.first?.projectXCConfig["Debug"])
        XCTAssertTrue(xcconfig.path.hasPrefix(dir.path), xcconfig.path)
        XCTAssertTrue(fm.fileExists(atPath: xcconfig.path))
        XCTAssertEqual(try XCConfigFile.load(url: xcconfig).includes.map(\.lastPathComponent), ["base.xcconfig"])
        XCTAssertTrue(try XCTUnwrap(model.allTargets.first).hasSwiftSources, "synchronized folder under the odd path")
        let legacy = try copy("AcmeLegacy", into: dir)
        let legacyModel = try ProjectModel.load(container: legacy, scheme: nil)
        XCTAssertEqual(legacyModel.allTargets.map(\.hasCSources), [false, true])
    }

    func testObjectVersion90ScriptArraysAndUserSchemes() throws {
        let legacy = try copy("AcmeLegacy", into: try scratch())
        let project = legacy.appendingPathComponent("AcmeLegacy.xcodeproj")
        try edit(project.appendingPathComponent("project.pbxproj")) {
            $0.replacingOccurrences(of: "objectVersion = 56;", with: "objectVersion = 90;")
                .replacingOccurrences(of: #"shellScript = "/usr/libexec/PlistBuddy -c \"Set :CFBundleVersion $(date +%s)\" \"$TARGET_BUILD_DIR/$INFOPLIST_PATH\"\n";"#,
                                      with: #"shellScript = ("set -e", "echo \"two\"", ); alwaysOutOfDate = 1; runOnlyForDeploymentPostprocessing = 1;"#)
        }
        let user = project.appendingPathComponent("xcuserdata/someone.xcuserdatad/xcschemes")
        try fm.createDirectory(at: user, withIntermediateDirectories: true)
        try Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <Scheme version = "1.7">
               <BuildAction></BuildAction>
               <LaunchAction buildConfiguration = "Release"></LaunchAction>
            </Scheme>
            """.utf8).write(to: user.appendingPathComponent("Mine.xcscheme"))
        try Data("not xml".utf8).write(to: user.appendingPathComponent("Broken.xcscheme"))

        let model = try ProjectModel.load(container: project, scheme: "Mine")
        XCTAssertEqual(model.format, .pbxproj(objectVersion: 90))
        let app = try XCTUnwrap(model.allTargets.first)
        let phase = try XCTUnwrap(app.phases.compactMap { phase -> ProjectModel.ShellScriptPhase? in
            if case let .shellScript(script) = phase { return script } else { return nil }
        }.first)
        XCTAssertEqual(phase.shellScript, "set -e\necho \"two\"")
        XCTAssertTrue(phase.alwaysOutOfDate)
        XCTAssertTrue(phase.runOnlyForDeploymentPostprocessing)

        XCTAssertEqual(model.schemes.map(\.name), ["AcmeLegacy", "Mine"])
        let mine = model.schemes[1]
        XCTAssertFalse(mine.isShared)
        XCTAssertNil(mine.parallelizeBuildables)
        XCTAssertNil(mine.buildImplicitDependencies)
        XCTAssertEqual(model.projects.first?.defaultConfiguration, "Release", "the requested scheme's LaunchAction")
        XCTAssertTrue(model.notes.contains { $0.contains("Broken.xcscheme is not readable XML") }, "\(model.notes)")

        let unknown = try ProjectModel.load(container: project, scheme: "Nope")
        XCTAssertTrue(unknown.notes.contains("scheme Nope not found among the shared and user schemes"))
        XCTAssertEqual(unknown.projects.first?.defaultConfiguration, "Debug")
    }

    func testSynchronizedFolderExceptionsAndLargeResources() throws {
        let precedence = try copy("Precedence", into: try scratch())
        let probe = precedence.appendingPathComponent("Probe")
        try Data("let excluded = 1\n".utf8).write(to: probe.appendingPathComponent("Excluded.swift"))
        try Data("int helper(void) { return 1; }\n".utf8).write(to: probe.appendingPathComponent("Helper.c"))
        let big = probe.appendingPathComponent("Intro.mov")
        fm.createFile(atPath: big.path, contents: nil)
        let handle = try FileHandle(forWritingTo: big)
        try handle.truncate(atOffset: 11 * 1024 * 1024)
        try handle.close()
        try Data("{}".utf8).write(to: probe.appendingPathComponent("small.json"))
        try fm.createDirectory(at: probe.appendingPathComponent("Assets.xcassets/AppIcon.appiconset"),
                               withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: probe.appendingPathComponent("Assets.xcassets/AppIcon.appiconset/Contents.json"))
        try edit(precedence.appendingPathComponent("Precedence.xcodeproj/project.pbxproj")) {
            $0.replacingOccurrences(of: "path = Probe;", with: "exceptions = (CA00000000000000000000F0); path = Probe;")
                .replacingOccurrences(of: "/* Begin PBXFileSystemSynchronizedRootGroup section */", with: """
                CA00000000000000000000F0 = {isa = PBXFileSystemSynchronizedBuildFileExceptionSet; membershipExceptions = (Excluded.swift, Helper.c); target = CA0000000000000000000030; };
                /* Begin PBXFileSystemSynchronizedRootGroup section */
                """)
        }
        let model = try ProjectModel.load(container: precedence, scheme: nil)
        let target = try XCTUnwrap(model.allTargets.first)
        XCTAssertFalse(target.hasCSources, "Helper.c is a membership exception")
        XCTAssertTrue(target.phases.contains(.sources(count: 1)), "\(target.phases)")
        XCTAssertTrue(target.phases.contains(.resources(count: 3, largeFileBytes: 11 * 1024 * 1024)), "\(target.phases)")
    }

    func testMissingXCConfigsAndIncludesBecomeNotes() throws {
        let precedence = try copy("Precedence", into: try scratch())
        let config = precedence.appendingPathComponent("Config")
        try edit(config.appendingPathComponent("target.xcconfig")) {
            "#include \"gone.xcconfig\"\n#include \"$(SRCROOT)/Config/base.xcconfig\"\nWRAPPED = a \\\n" + $0
        }
        try fm.removeItem(at: config.appendingPathComponent("base.xcconfig"))
        let model = try ProjectModel.load(container: precedence, scheme: nil)
        let notes = model.notes.joined(separator: "\n")
        XCTAssertTrue(notes.contains("gone.xcconfig does not exist (the build fails)"), notes)
        XCTAssertTrue(notes.contains("base.xcconfig does not exist (the build fails)"), notes)
        XCTAssertTrue(notes.contains("#include \"$(SRCROOT)/Config/base.xcconfig\" left as written"), notes)
        XCTAssertTrue(notes.contains("line continuations"), notes)
        XCTAssertFalse(notes.contains("missing.xcconfig"), notes)

        try fm.removeItem(at: config.appendingPathComponent("project.xcconfig"))
        let gone = try ProjectModel.load(container: precedence, scheme: nil)
        XCTAssertEqual(gone.projects.first?.projectXCConfig["Debug"]?.lastPathComponent, "project.xcconfig",
                       "the reference is kept even when the file is gone")
        XCTAssertTrue(gone.notes.contains { $0.hasPrefix("xcconfig not found:") && $0.contains("project.xcconfig") })
    }

    /// DESIGN §11 v0.3 gate: the reader's share of `doctor` on 200 targets.
    func testLargeProjectLoadsUnderHalfASecond() throws {
        let dir = fm.temporaryDirectory.appendingPathComponent("xcblame-large-fixture-200")
        let project = dir.appendingPathComponent("Large.xcodeproj")
        if !fm.fileExists(atPath: project.appendingPathComponent("project.pbxproj").path) {
            let script = fixtures.deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Scripts/make-large-fixture.sh")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [script.path, dir.path, "200"]
            process.standardOutput = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
        }
        let start = Date()
        let model = try ProjectModel.load(container: project, scheme: nil)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 0.5)
        XCTAssertEqual(model.allTargets.count, 200)
        XCTAssertEqual(model.allTargets.first?.name, "LargeApp")
        XCTAssertEqual(model.allTargets.first?.dependencies, ["Module002", "Module003"])
        let noOutputScripts = model.allTargets.flatMap(\.phases).filter {
            if case let .shellScript(phase) = $0 { return phase.outputPaths.isEmpty && phase.outputFileListPaths.isEmpty }
            return false
        }
        XCTAssertEqual(noOutputScripts.count, 20)
        XCTAssertTrue(model.allTargets.allSatisfy { $0.hasSwiftSources })
    }
}
