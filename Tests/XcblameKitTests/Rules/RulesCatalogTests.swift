import XCTest
@testable import XcblameKit

/// Catalog integrity against docs/RULES.md: ids, verbatim columns, gating flags.
final class RulesCatalogTests: XCTestCase {
    /// RULES.md table rows: id → cells (ID, Name, Det, Signal, Fix, Apply, Impact, Risk, Cfg, Xcode, Ev).
    static let rows: [String: [String]] = {
        let url = RulesFixtures.root.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("docs/RULES.md")
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        var rows: [String: [String]] = [:]
        for line in text.split(separator: "\n") where line.hasPrefix("| ") {
            let cells = line.dropFirst(2).dropLast(2).components(separatedBy: " | ").map { $0.trimmingCharacters(in: .whitespaces) }
            guard cells.count == 11, cells[0].range(of: #"^[A-Z]+-\d{3}$"#, options: .regularExpression) != nil else { continue }
            rows[cells[0]] = cells
        }
        return rows
    }()

    func testIdsAreUniqueAndEveryIdIsARulesMarkdownRow() throws {
        XCTAssertGreaterThan(Self.rows.count, 100, "parsed the RULES.md tables")
        let ids = RuleCatalog.all.map(\.id)
        XCTAssertEqual(ids.count, 49)
        XCTAssertEqual(Set(ids).count, ids.count, "unique ids")
        for id in ids { XCTAssertNotNil(Self.rows[id], "\(id) is a RULES.md row") }
        XCTAssertEqual(Set(RuleCatalog.all.map(\.category)), [.set, .phase, .dep, .env])
    }

    func testSpecsCarryTheRowVerbatim() throws {
        for spec in RuleCatalog.all {
            let row = try XCTUnwrap(Self.rows[spec.id])
            XCTAssertEqual(spec.name, row[1], spec.id)
            XCTAssertEqual(spec.signal, row[3], spec.id)
            XCTAssertEqual(spec.fix, row[4], spec.id)
            XCTAssertEqual(spec.impactContext, row[6], spec.id)
            XCTAssertEqual(spec.risk, row[7], spec.id)
            XCTAssertEqual(spec.xcode, row[9], spec.id)
            XCTAssertEqual(spec.id.hasPrefix(spec.category.prefix + "-"), true, spec.id)
            if row[5].contains("+V") { XCTAssertTrue(spec.verifyOnly, "\(spec.id) +V") }
            // Every letter inside every bracket counts: `[S/K]` is S and K, `[S]/[K]` too (code review v0.3 #6).
            for tag in Self.tagLetters(row[10]) {
                XCTAssertTrue(spec.evidenceTag.text.contains(tag), "\(spec.id) tag \(tag) (row \(row[10]))")
            }
        }
    }

    /// `[S/K]` → S, K; `[S]/[K]` → S, K; `[P]` → P; text outside brackets is ignored.
    static func tagLetters(_ cell: String) -> Set<String> {
        var letters: Set<String> = []
        var rest = cell[...]
        while let open = rest.firstIndex(of: "["), let close = rest[open...].firstIndex(of: "]") {
            for part in rest[rest.index(after: open)..<close].split(separator: "/") where ["P", "S", "K"].contains(String(part)) {
                letters.insert(String(part))
            }
            rest = rest[rest.index(after: close)...]
        }
        return letters
    }

    func testMixedTagsParse() {
        XCTAssertEqual(Self.tagLetters("[S/K]"), ["S", "K"])
        XCTAssertEqual(Self.tagLetters("[S]/[K]"), ["S", "K"])
        XCTAssertEqual(Self.tagLetters("[S] (S22)"), ["S"])
        XCTAssertEqual(RuleCatalog.spec("SET-029")?.evidenceTag.text, "S/K")
        XCTAssertTrue(RuleCatalog.spec("SET-029")?.evidenceTag.isKnowledgeGated == true)
    }

    func testEverySpecHasSignalFixSourcesAndAKeyTemplate() {
        for spec in RuleCatalog.all {
            XCTAssertFalse(spec.signal.isEmpty, spec.id)
            XCTAssertFalse(spec.fix.isEmpty, spec.id)
            XCTAssertFalse(spec.sources.isEmpty, spec.id)
            XCTAssertFalse(spec.summary.isEmpty, spec.id)
            XCTAssertFalse(spec.applyKinds.isEmpty, spec.id)
            XCTAssertFalse(spec.signalKeyTemplate.isEmpty, spec.id)
            XCTAssertNotEqual(spec.detection, .info, spec.id)
            for source in spec.sources {
                XCTAssertTrue(source.hasPrefix("https://") || source.hasPrefix("["), "\(spec.id) source \(source)")
            }
        }
        XCTAssertEqual(RuleCatalog.spec("SET-016")?.sources.first, "[OC] A16")
    }

    /// RULES.md §0 / §10: every [K]-gated rule is `+V`, and the §10 list is `+V`.
    func testKnowledgeGatedAndSection10RulesAreVerifyOnly() {
        for spec in RuleCatalog.all where spec.evidenceTag.isKnowledgeGated {
            XCTAssertTrue(spec.verifyOnly, "\(spec.id) [K] → +V")
            XCTAssertTrue(Confidence.needsMeasurement(spec, band: "S"), "\(spec.id) [K] needs measurement even when measured")
        }
        for id in ["SET-016", "SET-022", "SET-023", "SET-028", "SET-029", "SET-030"] {
            XCTAssertEqual(RuleCatalog.spec(id)?.verifyOnly, true, id)
        }
        XCTAssertEqual(RuleCatalog.all.filter { $0.evidenceTag.isKnowledgeGated }.map(\.id),
                       ["SET-006", "SET-011", "SET-014", "SET-022", "SET-029", "SET-032", "DEP-003", "ENV-003", "ENV-004", "ENV-006"])
    }

    func testAliasesResolveCaseInsensitively() {
        XCTAssertEqual(RuleCatalog.spec("phase-006")?.id, "PHASE-002")
        XCTAssertEqual(RuleCatalog.spec("SRC-010")?.id, "SET-007")
        XCTAssertEqual(RuleCatalog.spec("CI-005")?.id, "SET-008")
        XCTAssertEqual(RuleCatalog.spec("ci-007")?.id, "SET-017")
        XCTAssertNil(RuleCatalog.spec("SET-999"))
    }

    func testListTableHasOneRowPerRule() {
        let table = RuleCatalog.listTable(RuleCatalog.all)
        let lines = table.split(separator: "\n")
        XCTAssertEqual(lines.count, 50)
        XCTAssertTrue(lines[0].hasPrefix("ID "))
        XCTAssertTrue(lines.contains { $0.hasPrefix("ENV-004") && $0.contains(" ENV ") && $0.contains("rec +V") && $0.hasSuffix("K") })
    }
}
