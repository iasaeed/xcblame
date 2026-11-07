import CryptoKit
import XCTest
@testable import XcblameKit

/// The CI, release, formula and example files (docs/SCHEMA-v0.4.md "Lane C"). Nothing here publishes anything; the
/// tests check that the files exist, parse and contain the steps the design asks for.
final class ReleaseScaffoldingTests: XCTestCase {
    private let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    private func text(_ path: String, file: StaticString = #filePath, line: UInt = #line) throws -> String {
        let url = root.appendingPathComponent(path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "\(path) exists", file: file, line: line)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func assertContains(_ body: String, _ fragments: [String], in name: String, file: StaticString = #filePath,
                                line: UInt = #line) {
        for fragment in fragments { XCTAssertTrue(body.contains(fragment), "\(name) lacks `\(fragment)`", file: file, line: line) }
    }

    /// `ruby -ryaml` loads the file (the system ruby ships with macOS); returns the top-level keys (`on` parses as
    /// `true` in YAML 1.1), or nil without ruby.
    private func yamlKeys(_ path: String) throws -> [String]? {
        let ruby = "/usr/bin/ruby"
        guard FileManager.default.isExecutableFile(atPath: ruby) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ruby)
        process.arguments = ["-ryaml", "-e", "puts YAML.load_file(ARGV[0]).keys.map(&:to_s).join(',')",
                             root.appendingPathComponent(path).path]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "\(path) is valid YAML")
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ",").map(String.init)
    }

    func testCIWorkflow() throws {
        let ci = try text(".github/workflows/ci.yml")
        assertContains(ci, [
            "runs-on: macos-15", "maxim-lobanov/setup-xcode", "latest-stable", "run: swift build", "run: swift test",
            "fixtures/logs/cli-xcode26/", " analyze ", "--format html -o out/report.html", "actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02 # v4.6.2",
            "path: out/report.html", "--format github -o out/comment.md", "schema --document report > out/schema.json",
            "out/comment.md\n            out/schema.json",
        ], in: "ci.yml")
        XCTAssertFalse(ci.contains("\t"), "no tabs in YAML")
        if let keys = try yamlKeys(".github/workflows/ci.yml") { XCTAssertEqual(Set(keys).intersection(["name", "on", "true", "jobs"]).count, 3) }
        // The fixture the workflow analyzes is a real file of the repository.
        let log = try XCTUnwrap(ci.components(separatedBy: "FIXTURE_LOG: ").last?.split(separator: "\n").first)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(String(log)).path), String(log))
    }

    func testReleaseWorkflow() throws {
        let release = try text(".github/workflows/release.yml")
        assertContains(release, [
            "tags: ['v*']", "runs-on: macos-15", "swift build -c release --arch arm64 --arch x86_64", "lipo -info",
            "APPLE_CERT_P12", "APPLE_CERT_PASSWORD", "APPLE_ID", "APPLE_TEAM_ID", "APPLE_APP_PASSWORD",
            "codesign --force --options runtime", "notarytool submit", "Codesign skipped", "Notarization skipped",
            "make dist-tarball", "gh release create", "make formula", "Homebrew formula",
        ], in: "release.yml")
        XCTAssertFalse(release.contains("\t"))
        if let keys = try yamlKeys(".github/workflows/release.yml") { XCTAssertEqual(Set(keys).intersection(["name", "on", "true", "jobs"]).count, 3) }
        // Every secret is read through `env`, because `if:` cannot see `secrets`.
        XCTAssertFalse(release.contains("if: ${{ secrets."))
        // Code review v0.4 M5: the Apple secrets are step-level `env` of Codesign and Notarize only, never job-level,
        // and every action is pinned by a full commit SHA.
        let jobEnv = try XCTUnwrap(release.components(separatedBy: "    env:\n").dropFirst().first?
            .components(separatedBy: "    steps:").first)
        XCTAssertFalse(jobEnv.contains("APPLE_"), "job-level env holds no Apple secret")
        for name in ["Codesign", "Notarize"] {
            let step = try XCTUnwrap(release.components(separatedBy: "      - name: \(name)\n").dropFirst().first?
                .components(separatedBy: "\n      - name:").first)
            XCTAssertTrue(step.contains("        env:\n          APPLE_"), "\(name) has the secrets as step env")
        }
        let uses = release.split(separator: "\n").filter { $0.contains("uses:") }
        XCTAssertFalse(uses.isEmpty)
        for line in uses {
            XCTAssertNotNil(line.range(of: "@[0-9a-f]{40} # v[0-9]", options: .regularExpression), "\(line) is not SHA-pinned")
        }
    }

    func testMakefileReleaseTargets() throws {
        let makefile = try text("Makefile")
        assertContains(makefile, ["dist-binary:", "dist-tarball:", "release:", "formula:", "--arch arm64 --arch x86_64",
                                  "shasum -a 256", "Scripts/make-formula.sh"], in: "Makefile")
        XCTAssertTrue(try text(".gitignore").contains("dist/"))
    }

    func testFormulaTemplateIsFilledFromATarball() throws {
        let template = try text("Formula/xcblame.rb")
        assertContains(template, ["class Xcblame < Formula", "__URL__", "__SHA256__", "__VERSION__", "__HOMEPAGE__",
                                  "bin.install \"xcblame\"", "xcblame --version"], in: "xcblame.rb")
        let dir = try makeScratchDirectory()
        let tarball = dir.appendingPathComponent("xcblame-9.9.9-macos-universal.tar.gz")
        try Data("not really a tarball".utf8).write(to: tarball)
        let output = dir.appendingPathComponent("out/xcblame.rb")
        let url = "https://github.com/acme/xcblame/releases/download/v9.9.9/xcblame-9.9.9-macos-universal.tar.gz"
        let process = Process()
        process.executableURL = root.appendingPathComponent("Scripts/make-formula.sh")
        process.arguments = [tarball.path, url, "", output.path]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let formula = try String(contentsOf: output, encoding: .utf8)
        XCTAssertTrue(formula.contains("version \"9.9.9\""), formula)
        XCTAssertTrue(formula.contains("url \"\(url)\""), formula)
        XCTAssertTrue(formula.contains("homepage \"https://github.com/acme/xcblame\""), formula)
        // sha256 of the bytes above.
        XCTAssertTrue(formula.contains("sha256 \"\(sha256Hex(of: Data("not really a tarball".utf8)))\""), formula)
        XCTAssertNil(formula.range(of: "__[A-Z0-9]+__", options: .regularExpression))
    }

    private func sha256Hex(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func testExamples() throws {
        let action = try text("examples/github-action/xcblame.yml")
        assertContains(action, [
            "xcblame build", "--html", "--format github -o xcblame-comment.md", "-- \\", "gh pr comment", "--body-file xcblame-comment.md",
            "<!-- xcblame:report -->", "actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02 # v4.6.2", ".xcblame/reports/*.html", "--fail-if-slower", "if: always()",
        ], in: "xcblame.yml")
        XCTAssertFalse(action.contains("-- xcodebuild"), "arguments after `--` go to xcodebuild without its name")
        if let keys = try yamlKeys("examples/github-action/xcblame.yml") { XCTAssertEqual(Set(keys).intersection(["name", "on", "true", "jobs"]).count, 3) }

        let danger = try text("examples/danger/Dangerfile")
        assertContains(danger, ["require \"json\"", "xcblame.report/1", "regression", "diagnostics", "findings", "markdown(",
                                "--fail-if-slower 10", "def mention_safe", "def repo_relative"], in: "Dangerfile")
        // Review v0.4: the sample parses, and its helpers do what the comment says.
        let ruby = "/usr/bin/ruby"
        if FileManager.default.isExecutableFile(atPath: ruby) {
            let helpers = danger.components(separatedBy: "report = xcblame_report").first ?? ""
            let script = helpers + """
            ENV["GITHUB_WORKSPACE"] = "/ci/work/app"
            puts mention_safe("bad @octocat, `@keep`, \\\\`@dev\\\\`, a@b.c, @MainActor")
            puts mention_safe("a `b \\\\` @octocat c` d")
            puts repo_relative("/ci/work/app/Sources/A.swift").inspect
            puts repo_relative("/elsewhere/A.swift").inspect
            puts repo_relative("../A.swift").inspect
            """
            let process = Process()
            process.executableURL = URL(fileURLWithPath: ruby)
            process.arguments = ["-e", script]
            let out = Pipe()
            process.standardOutput = out
            process.standardError = Pipe()
            try process.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
            XCTAssertEqual(String(decoding: data, as: UTF8.self),
                           "bad `@octocat`, `@keep`, \\``@dev`\\`, a@b.c, `@MainActor`\na `b \\` `@octocat` c` d\n\"Sources/A.swift\"\nnil\nnil\n")
        }
        // Only fixture names in the examples.
        for body in [action, danger] { XCTAssertTrue(body.contains("Acme"), "uses the Acme* fixture names") }
    }
}
