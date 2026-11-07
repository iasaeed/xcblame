import Foundation
@testable import XcblameKit

/// Fixture access and raw-tree counters shared by the Gzip and SLF tests.
enum SLFFixtures {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("fixtures/logs")

    /// Xcode 26.0.1 command-line clean build (v11).
    static let cli26Clean = root.appendingPathComponent("cli-xcode26/20E8B73D-96FE-4232-8A33-311BFD02F961.xcactivitylog")
    /// Xcode 27.1 beta command-line clean build (v13).
    static let cli27Clean = root.appendingPathComponent(
        "cli-xcode27.1b/21F7B51C-4B90-49D4-B328-EDA168F7A9A5.xcactivitylog")

    static func logs(in dir: String) -> [URL] {
        let url = root.appendingPathComponent(dir)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        return names.filter { $0.hasSuffix(".xcactivitylog") }.sorted().map { url.appendingPathComponent($0) }
    }

    static var allLogs: [URL] { ["cli-xcode26", "cli-xcode27.1b", "ide-xcode26"].flatMap(logs(in:)) }

    static func inflated(_ url: URL) throws -> [UInt8] {
        try GzipFile.inflate(contentsOf: url).bytes
    }
}

struct RawCounts: Equatable {
    var sections = 0
    var messages = 0
    var attachments: [String: Int] = [:]
    var maxDepth = 0

    init(_ log: RawLog) { visit(log.root, depth: 0) }

    private mutating func visit(_ section: RawSection, depth: Int) {
        sections += 1
        maxDepth = max(maxDepth, depth)
        for message in section.messages { count(message) }
        for attachment in section.attachments { attachments[attachment.identifier, default: 0] += 1 }
        for child in section.subsections { visit(child, depth: depth + 1) }
    }

    private mutating func count(_ message: RawMessage) {
        messages += 1
        for sub in message.submessages { count(sub) }
    }
}

/// Emits SLF bytes for synthetic logs.
struct SLFWriter {
    var bytes = SLFTokenizer.header
    var classes: [String] = []

    mutating func int(_ v: Int) { bytes += Array("\(v)#".utf8) }
    mutating func str(_ s: String) { bytes += Array("\(s.utf8.count)\"".utf8) + Array(s.utf8) }
    mutating func json(_ s: String) { bytes += Array("\(s.utf8.count)*".utf8) + Array(s.utf8) }
    mutating func dbl(_ d: Double) {
        bytes += Array(String(format: "%016llx", d.bitPattern.byteSwapped).utf8) + [UInt8(ascii: "^")]
    }
    mutating func null() { bytes.append(UInt8(ascii: "-")) }
    mutating func arr(_ n: Int) { bytes += Array("\(n)(".utf8) }
    mutating func obj(_ name: String) {
        if !classes.contains(name) {
            classes.append(name)
            bytes += Array("\(name.utf8.count)%".utf8) + Array(name.utf8)
        }
        bytes += Array("\((classes.firstIndex(of: name) ?? 0) + 1)@".utf8)
    }

    /// v11 section lasting `duration` s; `head` injects tokens right after the class ref, `beforeSubtitle` /
    /// `afterCommand` inject drift, `omitStart` / `omitSignature` drop a slot, `location` writes the location slot.
    mutating func section(_ cls: String = "IDEActivityLogCommandInvocationSection", cd: String?, start: Double,
                          domain: String = "com.apple.dt.IDE.BuildLogSection",
                          duration: Double = 1, omitStart: Bool = false, omitSignature: Bool = false,
                          head: (inout SLFWriter) -> Void = { _ in },
                          children: (inout SLFWriter) -> Int = { _ in 0 },
                          beforeSubtitle: (inout SLFWriter) -> Void = { _ in },
                          afterCommand: (inout SLFWriter) -> Void = { _ in },
                          location: ((inout SLFWriter) -> Void)? = nil) {
        obj(cls)
        head(&self)
        int(2); str(domain); str("title")
        if !omitSignature { str(cd ?? "sig") }
        if !omitStart { dbl(start) }
        dbl(start + duration)
        var inner = SLFWriter(bytes: [], classes: classes)
        let count = children(&inner)
        classes = inner.classes
        if count > 0 { arr(count); bytes += inner.bytes } else { null() }
        null(); null()
        int(0); int(0); int(0)
        beforeSubtitle(&self)
        null()
        if let location { location(&self) } else { null() }
        if let cd { str(cd) } else { null() }
        afterCommand(&self)
        str("UUID"); null(); null(); arr(0)
    }

    /// A v11 command-line log: `BuildLog` container root at 100 s lasting `duration`, children from `body`.
    static func log(duration: Double = 1, _ body: (inout SLFWriter) -> Int) -> [UInt8] {
        var w = SLFWriter()
        w.int(11)
        w.section("IDECommandLineBuildLog", cd: nil, start: 100, domain: Locator.buildLogDomain, duration: duration,
                  children: body)
        return w.bytes
    }
}
