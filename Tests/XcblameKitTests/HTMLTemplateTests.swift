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
        XCTAssertLessThanOrEqual(ReportTemplate.html.utf8.count, 300_000, "template budget, DESIGN §8.2.5 (raised 2026-11-05)")
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

    /// Code review v0.2 #11: badge and path-label colours meet WCAG AA (4.5:1) in both themes; #12: kind colours are
    /// resolved once per draw, not per rectangle.
    func testBadgeAndPathColoursMeetAAAndKindColoursAreCached() throws {
        let html = ReportTemplate.html
        let dark = try XCTUnwrap(html.range(of: "@media (prefers-color-scheme: dark)"))
        func token(_ name: String, dark isDark: Bool) throws -> String {
            let range = isDark ? dark.upperBound..<html.endIndex : html.startIndex..<dark.lowerBound
            let start = try XCTUnwrap(html.range(of: "\(name): #", range: range), name).upperBound
            return String(html[start...].prefix(6))
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
        for isDark in [false, true] {
            for (ink, ground) in [("--warn", "--warn-bg"), ("--good", "--good-bg"), ("--bad", "--bad-bg"),
                                  ("--path-ink", "--path")] {
                let ratio = contrast(try token(ink, dark: isDark), try token(ground, dark: isDark))
                XCTAssertGreaterThanOrEqual(ratio, 4.5, "\(ink) on \(ground), dark \(isDark): \(ratio)")
            }
        }
        XCTAssertFalse(html.contains("fillStyle = cssVar(kindColorVar("), "kind colours come from the per-draw cache")
        XCTAssertTrue(html.contains("kindColor[kind] || (kindColor[kind] = cssVar(kindColorVar(kind)))"))
        XCTAssertTrue(html.contains("try { name = decodeURIComponent(m[1]); } catch"), "a malformed hash is ignored")
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
