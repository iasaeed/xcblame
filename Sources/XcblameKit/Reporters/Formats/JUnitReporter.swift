import Foundation

/// `--format junit`: one testcase per budget (docs/SCHEMA-v0.4.md "Formats", DESIGN §8.3). 
public enum JUnitReporter {
    /// `budgets` of `<xcblame-dir>/config.json` (seconds): `{"budgets": {"wall": 120, "incremental": 15,
    /// "criticalPath": 90, "targets": {"App": 40}}}`. Every member is optional.
    public struct Budgets: Codable, Sendable, Equatable {
        public var wall: Double?
        /// Applies when `build.kind` is `incremental`.
        public var incremental: Double?
        public var criticalPath: Double?
        /// Task seconds per target name (`rollups.byTarget[].taskTime`).
        public var targets: [String: Double]?

        public init(wall: Double? = nil, incremental: Double? = nil, criticalPath: Double? = nil,
                    targets: [String: Double]? = nil) {
            self.wall = wall
            self.incremental = incremental
            self.criticalPath = criticalPath
            self.targets = targets
        }
    }

    struct Case {
        var classname: String
        var name: String
        var time: Double
        var failure: (message: String, type: String, body: String)?
        var skipped: String?
    }

    public static func render(_ document: ReportDocument, options: FormatOptions) throws -> String {
        let budgets = ConfigFile.budgets(in: options.configURL)
        let wall = FormatText.wall(document)
        var cases: [Case] = [validation(document)]

        // The incremental budget replaces the wall budget for an incremental build; the testcase stays `wall`.
        let incremental = document.build.kind == "incremental" ? budgets.incremental : nil
        if let limit = incremental ?? budgets.wall {
            cases.append(budgetCase("wall", value: wall, limit: limit,
                                    label: incremental == nil ? "budget" : "incremental budget", what: "wall"))
        }
        if let limit = budgets.criticalPath {
            cases.append(budgetCase("criticalPath", value: document.criticalPath?.span, limit: limit, label: "budget",
                                    what: "critical path"))
        }
        for (name, limit) in (budgets.targets ?? [:]).sorted(by: { $0.key < $1.key }) {
            let row = document.targets?.first { $0.name == name && !$0.isOther }
            // `targets` holds the top N rows only (`--top`); a report cut that way cannot tell a small target from an
            // absent one, so the case says so instead of passing or failing it.
            let shown = document.targets?.filter { !$0.isOther }.count ?? 0
            let cut = document.targetsTotal > shown
                ? "target \(name) not among the \(shown) of \(document.targetsTotal) targets in the report; "
                    + "render with --top all to evaluate its budget"
                : "target \(name) not in the report"
            cases.append(budgetCase("target:\(name)", value: row?.taskTime, limit: limit, label: "budget",
                                    what: "target \(name) task time", missing: cut))
        }
        if let regression = document.regression {
            var item = Case(classname: "xcblame.regression", name: "wall", time: regression.wall.current ?? 0)
            if regression.failed {
                let pct = regression.wall.deltaPct.map { FormatText.signedPercent($0).replacingOccurrences(of: "+", with: "") }
                    ?? "an unknown amount"
                let limit = regression.thresholdPct.map { FormatText.threshold($0) } ?? "unknown"
                item.failure = ("slower than baseline by \(pct) (threshold \(limit))", "Regression",
                                "wall: \(FormatText.seconds(regression.wall.baseline)) -> "
                                    + "\(FormatText.seconds(regression.wall.current)); "
                                    + FormatText.regressionSentence(regression, bold: false))
            }
            cases.append(item)
        }

        let failures = cases.filter { $0.failure != nil }.count
        let skipped = cases.filter { $0.skipped != nil }.count
        let time = String(format: "%.3f", wall ?? 0)
        let counts = "tests=\"\(cases.count)\" failures=\"\(failures)\" errors=\"0\" skipped=\"\(skipped)\" time=\"\(time)\""
        var lines = ["<?xml version=\"1.0\" encoding=\"UTF-8\"?>",
                     "<testsuites name=\"xcblame\" \(counts)>",
                     "  <testsuite name=\"xcblame\" \(counts) timestamp=\"\(timestamp(document.generatedAt))\">"]
        let properties = self.properties(document)
        if !properties.isEmpty {
            lines.append("    <properties>")
            for (key, value) in properties { lines.append("      <property name=\"\(xml(key))\" value=\"\(xml(value))\"/>") }
            lines.append("    </properties>")
        }
        for item in cases { lines += caseLines(item) }
        lines += ["  </testsuite>", "</testsuites>"]
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: Cases

    private static func validation(_ document: ReportDocument) -> Case {
        var item = Case(classname: "xcblame.build", name: "validation", time: 0)
        let failed = document.validation.checks.filter { $0.status == "fail" }
        if !failed.isEmpty {
            let named = failed.map { "\($0.id) \(FormatText.oneLine($0.detail ?? $0.title))" }
            item.failure = ("validation failed: " + failed.map(\.id).joined(separator: ", "), "ValidationFailed",
                            named.joined(separator: "\n"))
        } else if document.degraded {
            let kinds = document.degradations.map { "\($0.kind): \(FormatText.oneLine($0.detail))" }
            item.failure = ("analysis degraded", "Degraded", kinds.joined(separator: "\n"))
        }
        return item
    }

    private static func budgetCase(_ name: String, value: Double?, limit: Double, label: String, what: String,
                                   missing: String? = nil) -> Case {
        var item = Case(classname: "xcblame.budget", name: name, time: value ?? 0)
        guard let value else {
            item.skipped = missing ?? "\(what) is unknown in this report"
            return item
        }
        if value > limit {
            item.failure = ("\(what) \(FormatText.seconds(value)) exceeds \(label) \(FormatText.seconds(limit))", "BudgetExceeded",
                            "\(what): \(FormatText.seconds(value)) (\(label) \(FormatText.seconds(limit)))")
        }
        return item
    }

    private static func caseLines(_ item: Case) -> [String] {
        let head = "    <testcase classname=\"\(xml(item.classname))\" name=\"\(xml(item.name))\" time=\"\(String(format: "%.3f", item.time))\""
        if let failure = item.failure {
            return [head + ">",
                    "      <failure message=\"\(xml(failure.message))\" type=\"\(xml(failure.type))\">\(xml(failure.body))</failure>",
                    "    </testcase>"]
        }
        if let reason = item.skipped { return [head + ">", "      <skipped message=\"\(xml(reason))\"/>", "    </testcase>"] }
        return [head + "/>"]
    }

    private static func properties(_ document: ReportDocument) -> [(String, String)] {
        var out = FormatText.buildKey(document).filter { $0.0 != "xcode" }
        if let xcode = document.xcode.value { out.append(("xcode", xcode)) }
        out.append(("tool", document.tool.version))
        if let git = document.environment?.git {
            if let commit = git.commit { out.append(("commit", commit)) }
            if let branch = git.branch { out.append(("branch", branch)) }
        }
        return out
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    /// XML 1.0 escaping (`& < > " '`) and removal of characters the XML 1.0 `Char` production forbids.
    static func xml(_ text: String) -> String {
        var out = ""
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x9, 0xA, 0xD, 0x20...0xD7FF, 0xE000...0xFFFD, 0x10000...0x10FFFF:
                switch scalar {
                case "&": out += "&amp;"
                case "<": out += "&lt;"
                case ">": out += "&gt;"
                case "\"": out += "&quot;"
                case "'": out += "&apos;"
                default: out.unicodeScalars.append(scalar)
                }
            default: continue
            }
        }
        return out
    }
}

/// The one key of `.xcblame/config.json` the formats read (`budgets`); no general config loader.
enum ConfigFile {
    /// `budgets` of the file; empty budgets for a missing file, a missing key or a nil URL. A malformed file (or a
    /// member of the wrong type) is a warning on stderr and counts as no budget.
    static func budgets(in url: URL?) -> JUnitReporter.Budgets {
        guard let url, let data = try? Data(contentsOf: url) else { return JUnitReporter.Budgets() }
        func warn(_ text: String) {
            FileHandle.standardError.write(Data("warning: \(url.lastPathComponent): \(text); no budgets applied\n".utf8))
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            warn("not a JSON object")
            return JUnitReporter.Budgets()
        }
        guard let raw = root["budgets"] else { return JUnitReporter.Budgets() }
        guard let object = raw as? [String: Any] else {
            warn("\"budgets\" is not an object")
            return JUnitReporter.Budgets()
        }
        func seconds(_ key: String, _ value: Any?) -> Double? {
            guard let value else { return nil }
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue >= 0,
                  number.doubleValue.isFinite else {
                warn("budgets.\(key) is not a number of seconds")
                return nil
            }
            return number.doubleValue
        }
        var budgets = JUnitReporter.Budgets(wall: seconds("wall", object["wall"]),
                                            incremental: seconds("incremental", object["incremental"]),
                                            criticalPath: seconds("criticalPath", object["criticalPath"]))
        if let targets = object["targets"] {
            if let table = targets as? [String: Any] {
                budgets.targets = table.keys.sorted().reduce(into: [:]) { result, name in
                    if let value = seconds("targets.\(name)", table[name]) { result[name] = value }
                }
            } else {
                warn("budgets.targets is not an object")
            }
        }
        return budgets
    }
}
