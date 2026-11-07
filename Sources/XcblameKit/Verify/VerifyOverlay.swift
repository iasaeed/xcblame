import Foundation

// v0.6 lane B (docs/SCHEMA-v0.6.md "Overlay file", "Mechanisms in verify"): the overlay text verify reads and writes.
// Arm B of `--mechanism hook` writes the unit's lines as temporary blocks and the exact bytes come back after each B
// run and on SIGINT/SIGTERM (`OverlayGuard`, `VerifySignals`); a reverted step that `fix --apply` wrote loses its plan
// block (`removingPlanBlocks`, byte-exact). The block format (header, begin/end lines, parsing) is lane A's
// `OverlayFile`, the one source of truth.
public enum VerifyOverlay {
    public enum OverlayError: Error, Sendable, Equatable, CustomStringConvertible {
        case editedByHand(String)

        public var description: String {
            switch self {
            case let .editedByHand(file): return "\(file): a block has no end line (the overlay was edited by hand)"
            }
        }
    }

    /// `<xcblame-dir>/overlay-<Configuration>.xcconfig`.
    public static func url(xcblameDir: URL, configuration: String) -> URL {
        OverlayFile.url(xcblameDir: xcblameDir, configuration: configuration)
    }

    /// `<xcblame-dir>/tmp/verify-overlay-<Configuration>.xcconfig`: the overlay the `cli` wrapper includes.
    public static func cliURL(xcblameDir: URL, configuration: String) -> URL {
        xcblameDir.appendingPathComponent("tmp/verify-overlay-\(configuration).xcconfig")
    }

    /// The header of a new overlay file (`OverlayFile.header`; each block brings its own blank line before it).
    public static func header(configuration: String) -> String { OverlayFile.header(configuration: configuration) }

    /// Whether `text` holds the plan block of `rule`.
    public static func hasPlanBlock(_ text: String, plan: String, rule: String) -> Bool {
        text.components(separatedBy: "\n").contains(OverlayFile.beginLine(planId: plan, ruleId: rule))
    }

    /// `text` without the plan blocks of `rules` (each the bytes apply inserted: the newline before the block, the
    /// begin line, its lines and the end line; `OverlayFile.blocks`). An unmatched begin or end line throws
    /// `editedByHand`.
    public static func removingPlanBlocks(_ text: String, plan: String, rules: [String], file: String) throws -> String {
        try removingBlocks(text, file: file) { $0.planId == plan && rules.contains($0.ruleId) }
    }

    /// `text` without every block `remove` picks (plan or leftover temporary blocks), byte-exact.
    public static func removingBlocks(_ text: String, file: String, where remove: (OverlayFile.Block) -> Bool) throws
        -> String {
        let blocks: [OverlayFile.Block]
        do {
            blocks = try OverlayFile.blocks(in: text, path: file)
        } catch {
            throw OverlayError.editedByHand(file)
        }
        var out = text
        for block in blocks.reversed() where remove(block) { out.removeSubrange(block.range) }
        return out
    }

    /// Plan blocks of other plans that set one of `keys` (arm A must not keep a change the unit measures; review
    /// minor 6): `(planId, ruleId)` in file order.
    public static func otherPlanBlocks(_ text: String, plan: String, keys: Set<String>, file: String) throws
        -> [(planId: String, ruleId: String)] {
        let blocks: [OverlayFile.Block]
        do {
            blocks = try OverlayFile.blocks(in: text, path: file)
        } catch {
            throw OverlayError.editedByHand(file)
        }
        return blocks.filter { block in
            block.planId != plan && block.lines.contains { OverlayFile.key(of: $0).map(keys.contains) == true }
        }.map { ($0.planId, $0.ruleId) }
    }

    /// `base` (a new header when nil) with one temporary verify block per `(rule, lines)`, each after one blank line.
    public static func withTemporaryBlocks(_ base: String?, plan: String, configuration: String,
                                           blocks: [(rule: String, lines: [String])]) -> String {
        var text = base ?? header(configuration: configuration)
        if !text.isEmpty, !text.hasSuffix("\n") { text += "\n" }
        for block in blocks {
            text += "\n" + OverlayFile.verifyBeginLine(planId: plan, ruleId: block.rule) + "\n"
            for line in block.lines { text += line + "\n" }
            text += OverlayFile.verifyEndLine(planId: plan, ruleId: block.rule) + "\n"
        }
        return text
    }

    /// True when `text` holds no assignment (only comments and blank lines): a header left after the last block.
    public static func isEmptyOverlay(_ text: String) -> Bool {
        text.components(separatedBy: "\n").allSatisfy {
            let line = $0.trimmingCharacters(in: .whitespaces)
            return line.isEmpty || line.hasPrefix("//")
        }
    }
}

/// The exact bytes of every file verify writes, restored after each B run, at the end and from a signal handler.
/// With a `journal`, the original bytes are also on disk before the first write (`VerifyJournal`), so a verify killed
/// where no handler runs (SIGKILL, a crash) is undone by the next `fix`, `verify` or `build`; `restoreAll` removes it.
public final class OverlayGuard: @unchecked Sendable {
    private let lock = NSLock()
    /// Original bytes per path; nil: the file did not exist.
    private var originals: [String: Data?] = [:]
    /// Written before the first write of each file, removed by `restoreAll`.
    public var journal: VerifyJournal?

    public init(journal: VerifyJournal? = nil) { self.journal = journal }

    /// Writes `text` to `url` in place (same inode), remembering the bytes and modification time it had first. With
    /// `modificationDate` the file gets that time, so repeated writes of one text look the same to the build system
    /// (a B series of an incremental or zero-change kind does not re-plan for a new xcconfig mtime).
    public func write(_ text: String, to url: URL, modificationDate: Date? = nil) throws {
        lock.lock()
        defer { lock.unlock() }
        let key = url.standardizedFileURL.path
        let fm = FileManager.default
        if originals[key] == nil {
            let bytes = try? Data(contentsOf: url)
            let date = (try? fm.attributesOfItem(atPath: key))?[.modificationDate] as? Date
            // The journal first: if writing it fails, nothing is written into the overlay.
            try journal?.add(.init(path: key, original: bytes, modificationDate: date))
            originals[key] = .some(bytes)
            modified[key] = date
        } else {
            try journal?.ensureOnDisk()
        }
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        if let modificationDate { try? fm.setAttributes([.modificationDate: modificationDate], ofItemAtPath: key) }
    }

    private var modified: [String: Date] = [:]

    /// Puts back the original bytes of `url` (deletes it when it did not exist); no-op for a file never written.
    public func restore(_ url: URL) {
        lock.lock()
        defer { lock.unlock() }
        restoreLocked(url.standardizedFileURL.path)
    }

    public func restoreAll() {
        lock.lock()
        defer { lock.unlock() }
        for key in originals.keys.sorted() { restoreLocked(key) }
        journal?.remove()
    }

    private func restoreLocked(_ key: String) {
        guard let original = originals[key] else { return }
        let url = URL(fileURLWithPath: key)
        if let bytes = original {
            if (try? Data(contentsOf: url)) != bytes { try? bytes.write(to: url) }
            if let date = modified[key] { try? FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: key) }
        } else {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// The original bytes of `url` as remembered (nil when never written through this guard or absent).
    public func original(_ url: URL) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return originals[url.standardizedFileURL.path] ?? nil
    }
}

/// `<xcblame-dir>/tmp/verify-inflight.json`: the overlay files a `--mechanism hook` verify is about to write, with
/// their original bytes (base64), the plan, rules and pid. Written before arm B's first temporary block, removed once
/// the bytes are back. A journal whose pid is no longer alive is a verify that died where no handler ran: `recover`
/// (called at the start of `fix`, `verify` and `build`) puts the original bytes back (fix round 1, review M2).
public final class VerifyJournal: @unchecked Sendable {
    public struct Entry: Codable, Sendable, Equatable {
        public var path: String
        /// Base64 of the bytes before verify wrote; nil when the file did not exist.
        public var original: String?
        public var modificationDate: Date?

        public init(path: String, original: Data?, modificationDate: Date?) {
            self.path = path
            self.original = original?.base64EncodedString()
            self.modificationDate = modificationDate
        }
    }

    struct Document: Codable {
        var planId: String
        var rules: [String]
        var pid: Int32
        /// The process's start time (seconds since 1970, `sysctl kern.proc.pid`), so a reused pid is not mistaken for
        /// the verify (fix round 2, nit 7); nil in a journal written before it, or when it could not be read.
        var processStart: Double?
        var startedAt: Date
        var entries: [Entry]
    }

    public let url: URL
    private let lock = NSLock()
    private var document: Document
    private var onDisk = false

    public init(xcblameDir: URL, planId: String, rules: [String], pid: Int32 = getpid(), now: Date = Date()) {
        url = Self.url(xcblameDir: xcblameDir)
        document = Document(planId: planId, rules: rules, pid: pid, processStart: Self.processStart(pid), startedAt: now,
                            entries: [])
    }

    public static func url(xcblameDir: URL) -> URL { xcblameDir.appendingPathComponent("tmp/verify-inflight.json") }

    /// Records one file's original bytes and writes the journal (before the file is touched).
    func add(_ entry: Entry) throws {
        lock.lock()
        defer { lock.unlock() }
        if !document.entries.contains(where: { $0.path == entry.path }) { document.entries.append(entry) }
        try persistLocked()
    }

    /// Writes the journal again after `remove` (a later B run writes the overlay once more).
    func ensureOnDisk() throws {
        lock.lock()
        defer { lock.unlock() }
        if !onDisk { try persistLocked() }
    }

    func remove() {
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.removeItem(at: url)
        onDisk = false
    }

    private func persistLocked() throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(document).write(to: url, options: .atomic)
        onDisk = true
    }

    /// A left-over journal: when its verify is no longer running (pid dead, or reused by a process that started at
    /// another time), every journaled file whose bytes differ from the original gets the original bytes (and
    /// modification time) back, whichever arm wrote them (an arm A write strips the selected steps' applied blocks: fix
    /// round 2, finding 1), the journal is deleted, and one warning line is returned. Nil when there is no journal, its
    /// verify is still running, or nothing differed. `isAlive` is the test (pid, journaled start time; tests replace it).
    public static func recover(xcblameDir: URL, isAlive: (Int32, Double?) -> Bool = processIsAlive) -> String? {
        let url = url(xcblameDir: xcblameDir)
        guard let data = FileManager.default.contents(atPath: url.path) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let document = try? decoder.decode(Document.self, from: data) else {
            try? FileManager.default.removeItem(at: url)
            return "warning: removed an unreadable verify journal (\(url.lastPathComponent)); check the overlay files "
                + "for a // xcblame verify … (temporary) block (xcblame fix --revert <plan-id> removes it)"
        }
        guard document.pid != getpid(), !isAlive(document.pid, document.processStart) else { return nil }
        var restored: [String] = []
        var failed: [String] = []
        for entry in document.entries {
            let file = URL(fileURLWithPath: entry.path)
            let original = entry.original.flatMap { Data(base64Encoded: $0) }
            guard FileManager.default.contents(atPath: file.path) != original else { continue }
            do {
                if let original {
                    try original.write(to: file)
                    if let date = entry.modificationDate {
                        try? FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: file.path)
                    }
                } else {
                    try FileManager.default.removeItem(at: file)
                }
                restored.append(file.lastPathComponent)
            } catch {
                failed.append("\(file.lastPathComponent) (\(error))")
            }
        }
        guard failed.isEmpty else {
            return "warning: an interrupted verify of plan \(document.planId) (pid \(document.pid)) left the overlay changed; "
                + "could not restore " + failed.joined(separator: ", ") + " (restore it from git; xcblame fix --revert "
                + "\(document.planId) removes temporary blocks)"
        }
        try? FileManager.default.removeItem(at: url)
        if restored.isEmpty { return nil }
        return "warning: restored \(restored.joined(separator: ", ")) from an interrupted verify of plan \(document.planId) "
            + "(pid \(document.pid), rules \(document.rules.joined(separator: ", ")))"
    }

    /// `kill(pid, 0)` succeeds or fails with EPERM (alive, another user's), and, when `start` is known, the process
    /// with that pid started then (a reused pid belongs to another process: the verify is dead).
    public static func processIsAlive(_ pid: Int32, start: Double?) -> Bool {
        guard pid > 0, kill(pid, 0) == 0 || errno == EPERM else { return false }
        guard let start, let now = processStart(pid) else { return true }
        return abs(now - start) < 0.001
    }

    /// The start time of `pid` (seconds since 1970) from `sysctl kern.proc.pid.<pid>`; nil when it cannot be read.
    public static func processStart(_ pid: Int32) -> Double? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0, info.kp_proc.p_pid == pid else {
            return nil
        }
        let start = info.kp_proc.p_un.__p_starttime
        return Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000
    }
}

/// SIGINT/SIGTERM/SIGHUP/SIGQUIT while verify runs: `interrupt` is raised (its `onRaise` handlers stop the running
/// xcodebuild, see `XcodebuildRunner.Cancel`), then the overlay is restored; the harness stops after that build (exit
/// 6, `interrupted`). SIGHUP is what closing the terminal tab sends. The handlers are caught ones (no-op C handler plus
/// a dispatch source), so the xcodebuild child gets the default disposition and Ctrl-C still stops it.
/// A signal that is ignored when verify starts (`nohup`, a background job without job control) stays ignored (fix
/// round 2, finding 2).
public final class VerifySignals: @unchecked Sendable {
    private var sources: [DispatchSourceSignal] = []
    static let handled: [(Int32, String)] = [(SIGINT, "SIGINT"), (SIGTERM, "SIGTERM"), (SIGHUP, "SIGHUP"),
                                             (SIGQUIT, "SIGQUIT")]
    /// The signals this instance caught (the ones not ignored at start).
    public private(set) var installed: [String] = []

    /// The current disposition of `number` is `SIG_IGN` (`sigaction` query; nothing changes).
    static func isIgnored(_ number: Int32) -> Bool {
        var current = sigaction()
        guard sigaction(number, nil, &current) == 0 else { return false }
        return unsafeBitCast(current.__sigaction_u, to: Int.self) == 1 // SIG_IGN is (void (*)(int))1
    }

    public init(guard overlay: OverlayGuard, interrupt: VerifyInterrupt) {
        for (number, name) in Self.handled where !Self.isIgnored(number) {
            installed.append(name)
            signal(number) { _ in }
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler {
                interrupt.raise(name)
                overlay.restoreAll()
            }
            source.resume()
            sources.append(source)
        }
    }

    /// Cancels the sources and puts the default dispositions back (ignored signals were never touched).
    public func uninstall() {
        for source in sources { source.cancel() }
        sources = []
        for (number, name) in Self.handled where installed.contains(name) { signal(number, SIG_DFL) }
        installed = []
    }
}
