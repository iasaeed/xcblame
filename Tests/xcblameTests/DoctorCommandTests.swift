import Foundation
import XCTest

/// `doctor` and `rules` through the built binary, on the fixture projects (zero writes into them).
final class DoctorCommandTests: XCTestCase {
    private let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("fixtures/projects")

    /// `doctor` gets `state` as its `--xcblame-dir` (default: a fresh temporary one).
    private func run(_ arguments: [String], state shared: URL? = nil) throws -> (status: Int32, out: String, err: String) {
        let state = shared ?? FileManager.default.temporaryDirectory.appendingPathComponent("xcblame-state-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: state) }
        let process = Process()
        process.executableURL = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("xcblame")
        process.arguments = arguments + (arguments.first == "doctor" ? ["--xcblame-dir", state.path] : [])
        var env = ProcessInfo.processInfo.environment
        env["CI"] = nil
        env["NO_COLOR"] = "1"
        // The settings oracle's cache home: under .build for the whole test run, never ~/Library/Caches.
        env["XCBLAME_CACHE_DIR"] = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build/settings-test-cache/oracle-home").path
        process.environment = env
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: outData, as: UTF8.self), String(decoding: errData, as: UTF8.self))
    }

    func testRulesListPrintsTheCatalogTable() throws {
        let result = try run(["rules", "list"])
        XCTAssertEqual(result.status, 0, result.err)
        let lines = result.out.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.first?.split(separator: " "), ["ID", "NAME", "CAT", "DET", "APPLY", "EV"])
        XCTAssertTrue(lines.contains { $0.hasPrefix("SET-016") && $0.contains("overlay(D) +V") && $0.hasSuffix("S") }, result.out)
        XCTAssertEqual(lines.last, "49 of 49 rules · xcblame rules explain <id>")
        let phases = try run(["rules", "list", "--category", "phase"])
        XCTAssertEqual(phases.out.split(separator: "\n").filter { $0.hasPrefix("PHASE-") }.count, 6)
        let json = try run(["rules", "list", "--json"])
        XCTAssertEqual(json.status, 0, json.err)
        let specs = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.out.utf8)) as? [[String: Any]])
        XCTAssertEqual(specs.count, 49)
        XCTAssertEqual(specs.first?["id"] as? String, "SET-001")
    }

    func testRulesExplainPrintsTheDocAndResolvesAliases() throws {
        let result = try run(["rules", "explain", "set-016"])
        XCTAssertEqual(result.status, 0, result.err)
        XCTAssertTrue(result.out.hasPrefix("SET-016  compilation-cache-enable-caching"), result.out)
        XCTAssertTrue(result.out.contains("apply    overlay(D) +V"), result.out)
        let alias = try run(["rules", "explain", "PHASE-006"])
        XCTAssertTrue(alias.out.hasPrefix("PHASE-002  guard-release-only-scripts"), alias.out)
        let json = try run(["rules", "explain", "DEP-012", "--json"])
        let spec = try JSONSerialization.jsonObject(with: Data(json.out.utf8)) as? [String: Any]
        XCTAssertEqual(spec?["evidenceTag"] as? String, "S")
    }

    func testRulesExplainUnknownIdIsAUsageError() throws {
        let result = try run(["rules", "explain", "SET-999"])
        XCTAssertEqual(result.status, 2)
        XCTAssertTrue(result.err.contains("unknown rule SET-999"), result.err)
        XCTAssertEqual(try run(["rules", "list", "--category", "nope"]).status, 2)
    }

    func testDoctorOnAcmeApp() throws {
        let acme = fixtures.appendingPathComponent("AcmeApp").path
        let result = try run(["doctor", acme, "--offline"])
        XCTAssertEqual(result.status, 0, result.err)
        for id in ["SET-001", "SET-004", "PHASE-001", "DEP-001", "SET-016"] { XCTAssertTrue(result.out.contains(id), id) }
        XCTAssertTrue(result.out.contains("FINDINGS"), result.out)
        XCTAssertTrue(result.out.contains("offline resolver"), "the settings source is printed")
        XCTAssertEqual(try run(["doctor", acme, "--offline", "--fail-on", "low"]).status, 4)
    }

    /// `--redact` applies to doctor's text and json output as it does to html.
    func testDoctorRedactsTextAndJSON() throws {
        let acme = fixtures.appendingPathComponent("AcmeApp").path
        for format in ["json", "text"] {
            let result = try run(["doctor", acme, "--offline", "--format", format, "--redact"])
            XCTAssertEqual(result.status, 0, result.err)
            XCTAssertFalse(result.out.contains("/Users/") || result.out.contains("/home/"), "\(format): \(result.out)")
        }
    }

    /// Code review v0.3 major 4: a text run git-ignores the state folder (with `cache/`), keeps only the settings
    /// JSON there, and `--verbose` prints the oracle cache size.
    func testDoctorTextRunIgnoresItsStateFolderAndPrintsTheCacheSize() throws {
        let state = FileManager.default.temporaryDirectory.appendingPathComponent("xcblame-state-\(UUID().uuidString)")
        let result = try run(["doctor", fixtures.appendingPathComponent("Precedence").path, "--verbose"], state: state)
        XCTAssertEqual(result.status, 0, result.err)
        let ignore = try String(contentsOf: state.appendingPathComponent(".gitignore"), encoding: .utf8)
        XCTAssertTrue(ignore.split(separator: "\n").contains("cache/"), ignore)
        XCTAssertTrue(result.err.contains("verbose: settings-oracle cache "), result.err)
        let cached = try FileManager.default.contentsOfDirectory(atPath: state.appendingPathComponent("cache/settings").path)
        XCTAssertTrue(!cached.isEmpty && cached.allSatisfy { $0.hasSuffix(".json") }, "\(cached)")
    }

    /// Code review v0.3 #11: `--rules` naming no known rule is a usage error, not a silent pass of a CI gate.
    func testUnknownRuleIdsAreAUsageError() throws {
        let acme = fixtures.appendingPathComponent("AcmeApp").path
        let result = try run(["doctor", acme, "--offline", "--rules", "SET-01", "--fail-on", "medium"])
        XCTAssertEqual(result.status, 2, result.err)
        XCTAssertTrue(result.err.contains("no known rule among --rules SET-01"), result.err)
        XCTAssertEqual(try run(["doctor", acme, "--offline", "--rules", "SET-01,SET-002"]).status, 0, "one known id is enough")
    }

    func testDoctorJSONAndHTMLOutputsAndFailOn() throws {
        let acme = fixtures.appendingPathComponent("AcmeApp")
        let before = try snapshot(acme)
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("xcblame-doctor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: scratch) }
        // One state folder: the settings cache makes the later runs cheap.
        let state = scratch.appendingPathComponent("state")

        let jsonFile = scratch.appendingPathComponent("doctor.json")
        let json = try run(["doctor", acme.path, "--format", "json", "-o", jsonFile.path], state: state)
        XCTAssertEqual(json.status, 0, json.err)
        XCTAssertTrue(json.out.hasPrefix("wrote \(jsonFile.path) (json, "), json.out)
        XCTAssertTrue(json.out.contains("49 rules evaluated · settings: "), json.out)
        let doc = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: jsonFile)) as? [String: Any])
        let project = try XCTUnwrap(doc["project"] as? [String: Any])
        XCTAssertEqual(project["configurations"] as? [String], ["Debug", "Release"])
        XCTAssertNotNil(project["settingsSource"] as? String)
        XCTAssertEqual((doc["doctor"] as? [String: Any])?["rulesEvaluated"] as? Int, 49)

        let htmlFile = scratch.appendingPathComponent("doctor.html")
        let html = try run(["doctor", acme.path, "--format", "html", "-o", htmlFile.path], state: state)
        XCTAssertEqual(html.status, 0, html.err)
        XCTAssertTrue(html.out.hasPrefix("wrote \(htmlFile.path) (html, "), html.out)
        XCTAssertTrue(try String(contentsOf: htmlFile, encoding: .utf8).contains("id=\"xcblame-data\""))

        // AcmeApp has medium findings (SET-001 …): exit 4; nothing at high.
        XCTAssertEqual(try run(["doctor", acme.path, "--fail-on", "medium", "--format", "json", "-o", "/dev/null"], state: state).status, 4)
        XCTAssertEqual(try run(["doctor", acme.path, "--fail-on", "high", "--format", "json", "-o", "/dev/null"], state: state).status, 0)
        XCTAssertEqual(try snapshot(acme), before, "doctor wrote into the project")
    }

    func testCorruptProjectExits1() throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("xcblame-corrupt-\(UUID().uuidString)")
        let xcodeproj = scratch.appendingPathComponent("Broken.xcodeproj")
        try FileManager.default.createDirectory(at: xcodeproj, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: scratch) }
        try Data("{ this is not a property list".utf8).write(to: xcodeproj.appendingPathComponent("project.pbxproj"))
        let result = try run(["doctor", xcodeproj.path])
        XCTAssertEqual(result.status, 1, result.err)
        XCTAssertTrue(result.err.contains("could not read the project"), result.err)
        XCTAssertFalse(result.err.contains("build log"), result.err)
    }

    /// Relative path, size and mtime of every file and folder below `dir`.
    private func snapshot(_ dir: URL) throws -> [String] {
        let fm = FileManager.default
        return (fm.subpaths(atPath: dir.path) ?? []).sorted().map { path in
            let attributes = (try? fm.attributesOfItem(atPath: dir.appendingPathComponent(path).path)) ?? [:]
            return "\(path) \(attributes[.size] ?? "") \(attributes[.modificationDate] ?? "")"
        }
    }

    func testDoctorWithoutAProjectExits5() throws {
        let missing = try run(["doctor", "/nonexistent-\(UUID().uuidString)"])
        XCTAssertEqual(missing.status, 5)
        XCTAssertTrue(missing.err.contains("project not found"), missing.err)
        let empty = try run(["doctor", fixtures.path])
        XCTAssertEqual(empty.status, 5)
        XCTAssertTrue(empty.err.contains("no .xcworkspace, .xcodeproj or Package.swift"), empty.err)
    }

    func testDoctorUsageErrors() throws {
        let acme = fixtures.appendingPathComponent("AcmeApp")
        XCTAssertEqual(try run(["doctor", acme.path, "--project", acme.appendingPathComponent("AcmeApp.xcodeproj").path]).status, 2)
        XCTAssertEqual(try run(["doctor", acme.path, "--fail-on", "critical"]).status, 2)
        XCTAssertEqual(try run(["doctor", acme.path, "--category", "settings"]).status, 2)
    }
}
