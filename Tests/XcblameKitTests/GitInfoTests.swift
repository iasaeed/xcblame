import XCTest
@testable import XcblameKit

final class GitInfoTests: XCTestCase {
    private func git(_ directory: URL, _ arguments: String...) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", directory.path, "-c", "user.name=Acme", "-c", "user.email=acme@example.com",
                             "-c", "commit.gpgsign=false", "-c", "init.defaultBranch=main"] + arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "git \(arguments.joined(separator: " "))")
    }

    private func makeRepository() throws -> URL {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/git") else { throw XCTSkip("git not installed") }
        let dir = try makeScratchDirectory().resolvingSymlinksInPath()
        try git(dir, "init", "-q")
        try Data("one\n".utf8).write(to: dir.appendingPathComponent("a.txt"))
        try git(dir, "add", "a.txt")
        try git(dir, "commit", "-q", "-m", "first")
        return dir
    }

    func testCleanRepositoryReportsBranchCommitAndNoRemote() throws {
        let dir = try makeRepository()
        let info = try XCTUnwrap(GitInfo.capture(in: dir))
        XCTAssertEqual(info.branch, "main")
        XCTAssertEqual(info.commit?.count, 40)
        XCTAssertTrue(info.commit?.allSatisfy { $0.isHexDigit } == true)
        XCTAssertEqual(info.dirty, false)
        XCTAssertNil(info.remoteHost)
    }

    func testDirtyMeansTrackedChangesOnly() throws {
        let dir = try makeRepository()
        try Data("untracked\n".utf8).write(to: dir.appendingPathComponent("b.txt"))
        XCTAssertEqual(GitInfo.capture(in: dir)?.dirty, false, "an untracked file does not make the tree dirty")
        try Data("two\n".utf8).write(to: dir.appendingPathComponent("a.txt"))
        XCTAssertEqual(GitInfo.capture(in: dir)?.dirty, true)
    }

    func testDetachedHeadHasNoBranchAndTheRemoteIsReducedToItsHost() throws {
        let dir = try makeRepository()
        try git(dir, "remote", "add", "origin", "https://ann:secret@GitHub.com:8443/acme/app.git")
        let commit = try XCTUnwrap(GitInfo.capture(in: dir)?.commit)
        try git(dir, "checkout", "-q", "--detach", commit)
        let info = try XCTUnwrap(GitInfo.capture(in: dir))
        XCTAssertNil(info.branch)
        XCTAssertEqual(info.commit, commit)
        XCTAssertEqual(info.remoteHost, "github.com")
    }

    func testRepositoryWithoutCommitsHasABranchButNoCommit() throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/git") else { throw XCTSkip("git not installed") }
        let dir = try makeScratchDirectory().resolvingSymlinksInPath()
        try git(dir, "init", "-q")
        let info = try XCTUnwrap(GitInfo.capture(in: dir))
        XCTAssertEqual(info.branch, "main")
        XCTAssertNil(info.commit)
    }

    func testNonRepositoryIsNil() throws {
        let dir = try makeScratchDirectory().resolvingSymlinksInPath()
        XCTAssertNil(GitInfo.capture(in: dir))
    }

    func testProbeArgumentsAreReadOnlyAndTakeNoOptionalLocks() {
        let calls = LockedList()
        _ = GitInfo.capture(probe: { argv in
            calls.append(argv)
            return nil
        })
        XCTAssertEqual(calls.values.count, 1, "stops at the first failed probe")
        for argv in calls.values {
            XCTAssertEqual(Array(argv.prefix(2)), ["git", "--no-optional-locks"])
        }
    }

    func testInjectedProbeDrivesEveryMember() {
        let answers: [[String]: String] = [
            ["rev-parse", "--is-inside-work-tree"]: "true",
            ["symbolic-ref", "--short", "-q", "HEAD"]: "feature/x",
            ["rev-parse", "HEAD"]: String(repeating: "ab", count: 20),
            ["status", "--porcelain=v1", "--untracked-files=no", "--branch"]: "## feature/x\n M a.txt",
            ["config", "--get", "remote.origin.url"]: "git@gitlab.example.com:acme/app.git",
        ]
        let info = GitInfo.capture(probe: { argv in answers[Array(argv.dropFirst(2))] })
        XCTAssertEqual(info, GitInfo(branch: "feature/x", commit: String(repeating: "ab", count: 20), dirty: true,
                                     remoteHost: "gitlab.example.com"))
        XCTAssertNil(GitInfo.capture(probe: { _ in "x" }), "a probe that does not say `true` is not a repository")
    }

    func testRemoteHostKeepsOnlyTheHost() {
        XCTAssertEqual(GitInfo.remoteHost(of: "https://github.com/acme/app.git"), "github.com")
        XCTAssertEqual(GitInfo.remoteHost(of: "https://user:pw@git.example.com/acme/app"), "git.example.com")
        XCTAssertEqual(GitInfo.remoteHost(of: "ssh://git@github.com:22/acme/app.git"), "github.com")
        XCTAssertEqual(GitInfo.remoteHost(of: "git@github.com:acme/app.git"), "github.com")
        XCTAssertNil(GitInfo.remoteHost(of: "/Users/ann/repos/app.git"))
        XCTAssertNil(GitInfo.remoteHost(of: "file:///Users/ann/repos/app.git"))
        XCTAssertNil(GitInfo.remoteHost(of: "../app.git"))
        XCTAssertNil(GitInfo.remoteHost(of: ""))
    }

    func testEnvSnapshotCarriesGitAndOmitsItWhenNil() throws {
        let withGit = EnvSnapshot.capture(environment: [:], probe: { argv in
            argv.first == "git" ? (argv.contains("--is-inside-work-tree") ? "true" : nil) : nil
        })
        XCTAssertNotNil(withGit.git)
        let without = EnvSnapshot.capture(environment: [:], probe: { _ in nil })
        XCTAssertNil(without.git)
        let json = String(decoding: try JSONEncoder().encode(without), as: UTF8.self)
        XCTAssertFalse(json.contains("\"git\""))
    }
}

/// A thread-safe list for the `@Sendable` probe closure.
private final class LockedList: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [[String]] = []
    func append(_ item: [String]) { lock.lock(); items.append(item); lock.unlock() }
    var values: [[String]] { lock.lock(); defer { lock.unlock() }; return items }
}
