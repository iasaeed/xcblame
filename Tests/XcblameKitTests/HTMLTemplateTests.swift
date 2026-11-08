import Foundation
import XCTest
@testable import XcblameKit

/// DESIGN §8.2.5 (d) and (g): the template loads nothing and the embedded copy matches `report.html`.
final class HTMLTemplateTests: XCTestCase {
    private static let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Sources/XcblameKit/Resources/report.html")

    // (g) Drift: run `make template` after editing report.html.
    func testEmbeddedTemplateMatchesTheSourceFile() throws {
        let file = try Data(contentsOf: Self.source)
        XCTAssertEqual(Data(ReportTemplate.html.utf8), file, "ReportTemplate.swift is stale: run `make template`")
    }

    func testTemplateStaysUnderItsBudget() {
        XCTAssertLessThanOrEqual(ReportTemplate.html.utf8.count, 200_000, "template budget, DESIGN §8.2.5 (lowered 2026-11-08)")
    }

    // (d) No network references of any kind.
    func testTemplateHasNoNetworkReferences() throws {
        let html = ReportTemplate.html
        let patterns = [
            #"(src|href)\s*=\s*["']?[a-zA-Z][a-zA-Z0-9+.-]*:"#,   // a URL with a scheme in markup
            #"(src|href)\s*=\s*["']?//"#,                          // protocol-relative
            #"@import"#,
            #"(?<![a-z])url\(\s*["']?(?!data:)"#,
            #"fetch\s*\("#,
            #"XMLHttpRequest"#,
            #"<link\b"#,
            #"<iframe\b"#,
            #"\bimport\s*\("#,
            #"new\s+(WebSocket|EventSource|Worker)\b"#,
            #"sendBeacon"#,
        ]
        for pattern in patterns {
            let regex = try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
            let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html))
            XCTAssertNil(match, "network reference matching \(pattern): "
                + (match.map { String(html[Range($0.range, in: html)!]) } ?? ""))
        }
        XCTAssertTrue(html.contains("default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data:"))
    }

    /// Code review v0.2 #11 and the cockpit tokens (DESIGN §8.2.1 #5, light only): every text token meets WCAG AA
    /// (4.5:1) on the grounds it is used on; #12: kind colours are resolved once per draw, not per rectangle.
    func testTextTokensMeetAAInTheLightThemeAndKindColoursAreCached() throws {
        let html = ReportTemplate.html
        XCTAssertFalse(html.contains("prefers-color-scheme"), "light only: no dark theme")
        XCTAssertTrue(html.contains("<meta name=\"color-scheme\" content=\"light\">"))
        func token(_ name: String) throws -> String {
            let regex = try NSRegularExpression(pattern: NSRegularExpression.escapedPattern(for: name) + #"\s*:\s*#([0-9a-fA-F]{6}|[0-9a-fA-F]{3})\b"#)
            let match = try XCTUnwrap(regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)), "token \(name)")
            let hex = String(html[try XCTUnwrap(Range(match.range(at: 1), in: html))])
            return hex.count == 3 ? hex.map { "\($0)\($0)" }.joined() : hex
        }
        func luminance(_ hex: String) -> Double {
            let value = Int(hex, radix: 16) ?? 0
            return [(value >> 16) & 255, (value >> 8) & 255, value & 255].enumerated().reduce(0.0) { sum, item in
                let c = Double(item.element) / 255
                let linear = c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
                return sum + [0.2126, 0.7152, 0.0722][item.offset] * linear
            }
        }
        func contrast(_ a: String, _ b: String) -> Double {
            let (x, y) = (luminance(a), luminance(b))
            return (max(x, y) + 0.05) / (min(x, y) + 0.05)
        }
        var pairs: [(String, String)] = []
        for ink in ["--ink", "--ink-2", "--muted", "--accent-ink"] { pairs += [(ink, "--bg"), (ink, "--panel")] }
        for ink in ["--good", "--warn", "--bad"] { pairs.append((ink, "--bg")) }
        for (ink, ground) in pairs {
            let ratio = contrast(try token(ink), try token(ground))
            XCTAssertGreaterThanOrEqual(ratio, 4.5, "\(ink) on \(ground): \(ratio)")
        }
        // Action badges: #111 on the accent fill (white on #F97316 is 2.8:1).
        let badge = contrast("111111", try token("--accent"))
        XCTAssertGreaterThanOrEqual(badge, 4.5, "#111 on --accent: \(badge)")
        XCTAssertFalse(html.contains("fillStyle = cssVar(kindColorVar("), "kind colours come from the per-draw cache")
        XCTAssertTrue(html.contains("kindColor[kind] || (kindColor[kind] = cssVar(kindColorVar(kind)))"))
        XCTAssertTrue(html.contains("try { name = decodeURIComponent(m[1]); } catch"), "a malformed hash is ignored")
    }

    /// Prose rules of the cockpit decision (DESIGN §8.2.5, plan §5): (a) at most 200 static words in the markup, (b) at
    /// most 3,000 words in multi-word JS string literals, (c) every tooltip at most 12 words, (d) no banned strings.
    func testProseBudget() throws {
        let html = ReportTemplate.html
        let wordPattern = try NSRegularExpression(pattern: "[A-Za-z][A-Za-z'’-]*")
        func words(_ text: String) -> Int { wordPattern.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text)) }

        // (a) Static words: markup without scripts, styles, comments, tags, entities and placeholders.
        var markup = html
        for pattern in ["<script[^>]*>[\\s\\S]*?</script>", "<style[^>]*>[\\s\\S]*?</style>", "<!--[\\s\\S]*?-->", "<[^>]+>",
                        "\\{\\{[^}]*\\}\\}", "&#?[A-Za-z0-9]+;"] {
            markup = markup.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        let staticWords = words(markup)
        XCTAssertLessThanOrEqual(staticWords, 200, "static words")

        // (b) Words in multi-word JS string literals of the code script.
        let code = try XCTUnwrap(html.components(separatedBy: "<script>").dropFirst().first?.components(separatedBy: "</script>").first)
        let literals = Self.stringLiterals(code)
        let literalWords = literals.filter { $0.contains(" ") && words($0) >= 2 }.map(words).reduce(0, +)
        XCTAssertLessThanOrEqual(literalWords, 3_000, "words in multi-word string literals (ratchet down from here)")
        print("prose budget: static words \(staticWords), literal words \(literalWords), template bytes \(html.utf8.count)")

        // (c) Tooltips: static title="…" and JS title: '…' literals.
        let withoutScripts = html.replacingOccurrences(of: "<script[^>]*>[\\s\\S]*?</script>", with: " ", options: .regularExpression)
        var titles = matches(#"\btitle="([^"]*)""#, in: withoutScripts)
        titles += matches(#"\btitle:\s*'((?:[^'\\]|\\.)*)'"#, in: code) + matches(#"\btitle:\s*"((?:[^"\\]|\\.)*)""#, in: code)
        for title in titles {
            XCTAssertLessThanOrEqual(title.split(whereSeparator: \.isWhitespace).count, 12, "tooltip over 12 words: \(title)")
        }

        // (d) Banned strings ("glossary" in any case: the glossary moved to docs/REPORT.md).
        for banned in ["What this shows", "What to do:", "what-this-shows", "col-defs", "prefers-color-scheme"] {
            XCTAssertFalse(html.contains(banned), banned)
        }
        XCTAssertNil(html.range(of: "glossary", options: .caseInsensitive), "glossary")
    }

    private func matches(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range(at: 1), in: text).map { String(text[$0]) }
        }
    }

    /// The contents of every string literal ('…', "…", `…`) of `code`, skipping comments and regex literals.
    static func stringLiterals(_ code: String) -> [String] {
        let chars = Array(code.unicodeScalars)
        var out: [String] = []
        var i = 0
        var last: Unicode.Scalar = "("   // last significant character, to tell a regex literal from a division
        func read(until quote: Unicode.Scalar) -> String {
            var text = String.UnicodeScalarView()
            while i < chars.count, chars[i] != quote {
                if chars[i] == "\\", i + 1 < chars.count { text.append(chars[i + 1]); i += 2; continue }
                text.append(chars[i]); i += 1
            }
            i += 1
            return String(text)
        }
        while i < chars.count {
            let c = chars[i]
            let next: Unicode.Scalar? = i + 1 < chars.count ? chars[i + 1] : nil
            if c == "/", next == "/" {
                while i < chars.count, chars[i] != "\n" { i += 1 }
            } else if c == "/", next == "*" {
                i += 2
                while i + 1 < chars.count, !(chars[i] == "*" && chars[i + 1] == "/") { i += 1 }
                i += 2
            } else if c == "'" || c == "\"" || c == "`" {
                i += 1
                out.append(read(until: c))
                last = "a"
            } else if c == "/", "(,=:[!&|?{};+-*%<>~^".unicodeScalars.contains(last) || last == "\n" {
                i += 1
                var inClass = false
                while i < chars.count, chars[i] != "\n" {
                    if chars[i] == "\\" { i += 2; continue }
                    if chars[i] == "[" { inClass = true } else if chars[i] == "]" { inClass = false }
                    else if chars[i] == "/", !inClass { break }
                    i += 1
                }
                i += 1
                last = "a"
            } else {
                if !CharacterSet.whitespacesAndNewlines.contains(c) { last = c }
                i += 1
            }
        }
        return out
    }

    func testTemplateHasOneStyleAndOneCodeScriptAndNoInnerHTML() {
        let html = ReportTemplate.html
        XCTAssertEqual(html.components(separatedBy: "<style>").count - 1, 1)
        XCTAssertEqual(html.components(separatedBy: "<script>").count - 1, 1)
        XCTAssertEqual(html.components(separatedBy: "<script type=\"application/json\" id=\"xcblame-data\"").count - 1, 1)
        for banned in ["innerHTML", "outerHTML", "insertAdjacentHTML", "document.write", "eval(", "new Function"] {
            XCTAssertFalse(html.contains(banned), banned)
        }
        XCTAssertEqual(html.components(separatedBy: HTMLReporter.dataPlaceholder).count - 1, 1)
    }
}
