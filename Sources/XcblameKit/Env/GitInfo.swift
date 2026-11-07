import Foundation

/// Git state of the repository that holds the current directory (docs/SCHEMA-v0.4.md `environment.git`). It describes
/// the checkout running xcblame, like the rest of `EnvSnapshot`, not necessarily the one that built a log analyzed
/// after the fact.
public struct GitInfo: Codable, Sendable, Equatable {
    /// Current branch; nil on a detached HEAD.
    public var branch: String?
    /// Full 40-hex `HEAD` commit; nil outside a repository or without commits.
    public var commit: String?
    /// True when the work tree has uncommitted changes to tracked files (untracked files do not count).
    public var dirty: Bool?
    /// Host of `remote.origin.url` only (`github.com`): no user, password, path or port. Nil without an origin.
    public var remoteHost: String?

    public init(branch: String? = nil, commit: String? = nil, dirty: Bool? = nil, remoteHost: String? = nil) {
        self.branch = branch
        self.commit = commit
        self.dirty = dirty
        self.remoteHost = remoteHost
    }

    /// Probes `git` through the `EnvSnapshot` probe (argv in, trimmed stdout or nil out). Nil outside a repository or
    /// when git is missing. Every call is read-only and takes no optional locks (`--no-optional-locks` is the flag
    /// form of `GIT_OPTIONAL_LOCKS=0`, so a `git status` of the user's own is never blocked or refreshed);
    /// `runProbe` kills a call after 2 s and runs `/usr/bin/git`, never a PATH shim.
    public static func capture(probe: EnvSnapshot.Probe) -> GitInfo? {
        func git(_ arguments: String...) -> String? { probe(["git", "--no-optional-locks"] + arguments) }
        guard git("rev-parse", "--is-inside-work-tree") == "true" else { return nil }
        var info = GitInfo()
        info.branch = git("symbolic-ref", "--short", "-q", "HEAD")
        info.commit = git("rev-parse", "HEAD").flatMap { isObjectName($0) ? $0 : nil }
        // `--branch` makes the output non-empty on success, so a failed call (nil) differs from a clean tree.
        if let status = git("status", "--porcelain=v1", "--untracked-files=no", "--branch") {
            info.dirty = status.split(whereSeparator: \.isNewline).contains { !$0.hasPrefix("##") }
        }
        info.remoteHost = git("config", "--get", "remote.origin.url").flatMap(remoteHost(of:))
        return info
    }

    /// `capture(probe:)` for the repository that holds `directory` (`git -C`), through the real `git`.
    public static func capture(in directory: URL, timeout: TimeInterval = 2) -> GitInfo? {
        capture(probe: { argv in
            guard argv.first == "git" else { return nil }
            return runProbe(["git", "-C", directory.path] + argv.dropFirst(), timeout: timeout)
        })
    }

    /// 40 (SHA-1) or 64 (SHA-256) lowercase hex digits.
    static func isObjectName(_ text: String) -> Bool {
        (text.count == 40 || text.count == 64) && text.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    /// The host of a remote URL and nothing else: no user, password, path or port. Handles `https://user:pw@host/p`,
    /// `ssh://git@host:22/p` and scp-like `git@host:p`; a local path or an unparsable value gives nil.
    static func remoteHost(of url: String) -> String? {
        var text = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let scheme = text.range(of: "://") {
            text = String(text[scheme.upperBound...])
            if text.hasPrefix("/") { return nil }  // file:///path
        } else if text.hasPrefix("/") || text.hasPrefix(".") || text.hasPrefix("~") {
            return nil
        }
        // The authority ends at the first `/`; the user part ends at the last `@`; a port or scp path starts at `:`.
        var authority = String(text.prefix { $0 != "/" })
        if let at = authority.lastIndex(of: "@") { authority = String(authority[authority.index(after: at)...]) }
        authority = String(authority.prefix { $0 != ":" })
        let host = authority.lowercased()
        let valid = !host.isEmpty && host.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }
        return valid ? host : nil
    }
}
