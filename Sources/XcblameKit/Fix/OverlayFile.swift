import Foundation

// v0.6 lane A (docs/SCHEMA-v0.6.md "Overlay file"): `<xcblame-dir>/overlay-<Configuration>.xcconfig`, one block per
// (plan, rule) between matched begin and end lines. Apply appends blocks; revert removes exactly the bytes apply
// inserted, so apply then revert leaves every file byte-identical (the file is deleted when apply created it).
public enum OverlayFile {
    public enum OverlayError: Error, Sendable, Equatable, CustomStringConvertible {
        /// A begin line without its end line (or the reverse): the overlay was edited by hand.
        case handEdited(String)

        public var description: String {
            switch self {
            case let .handEdited(path):
                return "the overlay was edited by hand (\(path): an xcblame block has no matching end line); "
                    + "restore it from git or remove the block yourself"
            }
        }
    }

    /// One `// xcblame plan <id> rule <RULE>` … `// end xcblame plan <id> rule <RULE>` block, or a temporary
    /// `// xcblame verify <id> rule <RULE> (temporary)` … `// end xcblame verify <id> rule <RULE>` block an interrupted
    /// verify left behind (revertable like a plan block: `fix --revert <id>` removes it, apply sees its keys).
    public struct Block: Sendable, Equatable {
        public var planId: String
        public var ruleId: String
        /// The assignment lines between the begin and end lines, as written.
        public var lines: [String]
        /// A verify block (`--mechanism hook`, arm B), not a plan block `fix --apply` wrote.
        public var temporary = false
        /// Byte range in the file text of the block plus the one newline apply wrote before it (never overlapping the
        /// previous block when a hand edit removed the blank line between them).
        var range: Range<String.Index>
    }

    public static func url(xcblameDir: URL, configuration: String) -> URL {
        xcblameDir.appendingPathComponent("overlay-\(configuration).xcconfig")
    }

    /// Every overlay file in `xcblameDir`, sorted by name.
    public static func all(xcblameDir: URL) -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: xcblameDir, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.lastPathComponent.hasPrefix("overlay-") && $0.pathExtension == "xcconfig" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// The three header comment lines a new overlay file starts with.
    public static func header(configuration: String) -> String {
        "// xcblame overlay for configuration \(configuration). Written by xcblame fix --apply; each block belongs to\n"
            + "// one plan step and xcblame fix --revert <plan-id> removes it.\n"
            + "// Read through the #include? hook or the xcblame -xcconfig wrapper.\n"
    }

    public static func beginLine(planId: String, ruleId: String) -> String { "// xcblame plan \(planId) rule \(ruleId)" }
    public static func endLine(planId: String, ruleId: String) -> String { "// end xcblame plan \(planId) rule \(ruleId)" }
    /// Verify's temporary block (`--mechanism hook`, arm B; docs/SCHEMA-v0.6.md "Mechanisms in verify"): restored away
    /// after each B run; one left by a killed verify is a `temporary` block of `blocks(in:)`.
    public static func verifyBeginLine(planId: String, ruleId: String) -> String {
        "// xcblame verify \(planId) rule \(ruleId) (temporary)"
    }
    public static func verifyEndLine(planId: String, ruleId: String) -> String { "// end xcblame verify \(planId) rule \(ruleId)" }

    /// `KEY[cond] = VALUE // xcblame <RULE> (plan <id>)`.
    public static func line(key: String, condition: String?, value: String, ruleId: String, planId: String) -> String {
        "\(key)\(condition ?? "") = \(value) // xcblame \(ruleId) (plan \(planId))"
    }

    /// The key an assignment line sets (`KEY` of `KEY[sdk=…] = …`), nil for a comment, include or blank line.
    public static func key(of line: String) -> String? {
        let code = XCConfigChain.stripComment(line).trimmingCharacters(in: .whitespaces)
        guard !code.hasPrefix("#"), let eq = code.firstIndex(of: "=") else { return nil }
        var lhs = code[..<eq].trimmingCharacters(in: .whitespaces)
        if let bracket = lhs.firstIndex(of: "[") { lhs = String(lhs[..<bracket]) }
        return XCConfigChain.isIdentifier(lhs) ? lhs : nil
    }

    /// The xcblame blocks of `text` in file order: plan blocks and (`temporary`) verify blocks a killed verify left.
    /// Throws when a begin line has no matching end line or an end line no begin line.
    public static func blocks(in text: String, path: String) throws -> [Block] {
        var blocks: [Block] = []
        var open: (planId: String, ruleId: String, temporary: Bool, start: String.Index, lines: [String])?
        var index = text.startIndex
        while index < text.endIndex {
            let lineEnd = text[index...].firstIndex(of: "\n") ?? text.endIndex
            let line = String(text[index..<lineEnd])
            let next = lineEnd < text.endIndex ? text.index(after: lineEnd) : lineEnd
            let begin = parse(line, prefix: "// xcblame plan ").map { ($0.0, $0.1, false) }
                ?? parse(line, prefix: "// xcblame verify ", suffix: "(temporary)").map { ($0.0, $0.1, true) }
            let end = parse(line, prefix: "// end xcblame plan ").map { ($0.0, $0.1, false) }
                ?? parse(line, prefix: "// end xcblame verify ").map { ($0.0, $0.1, true) }
            if let (plan, rule, temporary) = begin {
                guard open == nil else { throw OverlayError.handEdited(path) }
                // The newline before the begin line is part of what apply inserted, unless it ends the previous block
                // (a hand edit removed the blank line between two blocks): ranges never overlap.
                var start = index > text.startIndex ? text.index(before: index) : index
                if let previous = blocks.last?.range.upperBound, start < previous { start = previous }
                open = (plan, rule, temporary, start, [])
            } else if let (plan, rule, temporary) = end {
                guard let current = open, current.planId == plan, current.ruleId == rule, current.temporary == temporary else {
                    throw OverlayError.handEdited(path)
                }
                blocks.append(Block(planId: plan, ruleId: rule, lines: current.lines, temporary: temporary,
                                    range: current.start..<next))
                open = nil
            } else if open != nil {
                open?.lines.append(line)
            }
            index = next
        }
        if open != nil { throw OverlayError.handEdited(path) }
        return blocks
    }

    /// `<prefix><id> rule <RULE>[ <suffix>]`.
    private static func parse(_ line: String, prefix: String, suffix: String? = nil) -> (String, String)? {
        guard line.hasPrefix(prefix) else { return nil }
        var parts = line.dropFirst(prefix.count).split(separator: " ").map(String.init)
        if let suffix {
            guard parts.last == suffix else { return nil }
            parts.removeLast()
        }
        guard parts.count == 3, parts[1] == "rule" else { return nil }
        return (parts[0], parts[2])
    }

    /// The text with one block appended: a newline (the blank line, or the end of an unterminated last line), the
    /// begin line, `lines`, the end line. A missing file starts with the header.
    public static func appending(planId: String, ruleId: String, lines: [String], to text: String?,
                                 configuration: String) -> String {
        var out = text ?? header(configuration: configuration)
        out += "\n" + beginLine(planId: planId, ruleId: ruleId) + "\n"
        for line in lines { out += line + "\n" }
        out += endLine(planId: planId, ruleId: ruleId) + "\n"
        return out
    }

    /// The text without the blocks of `planId` (exactly the bytes `appending` inserted). Nil when nothing is left but
    /// the header (apply created the file: delete it).
    public static func removing(planId: String, from text: String, configuration: String, path: String) throws
        -> (text: String?, removed: [Block]) {
        let all = try blocks(in: text, path: path)
        let mine = all.filter { $0.planId == planId }
        var out = text
        for block in mine.reversed() { out.removeSubrange(block.range) }
        return (out == header(configuration: configuration) ? nil : out, mine)
    }

    /// Keys set inside xcblame blocks, to the (plan, rule) block that sets them (`temporary`: a verify block a killed
    /// verify left).
    public static func owners(in text: String, path: String) throws
        -> [String: (planId: String, ruleId: String, temporary: Bool)] {
        var owners: [String: (planId: String, ruleId: String, temporary: Bool)] = [:]
        for block in try blocks(in: text, path: path) {
            for line in block.lines {
                if let key = key(of: line) { owners[key] = (block.planId, block.ruleId, block.temporary) }
            }
        }
        return owners
    }

    /// The configuration of an `overlay-<C>.xcconfig` file name.
    public static func configuration(of url: URL) -> String {
        String(url.deletingPathExtension().lastPathComponent.dropFirst("overlay-".count))
    }
}
