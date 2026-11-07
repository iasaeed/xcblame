import Foundation

/// Helpers shared by the four v0.4 text reporters (docs/SCHEMA-v0.4.md "Formats"). Everything here is a pure function
/// of its arguments: no environment reads, no clock, so two runs over the same document are byte-equal.
enum FormatText {
    // MARK: - Numbers

    /// `18.14 s`; `n/a` when unknown (never `0`).
    static func seconds(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "n/a" }
        return String(format: "%.2f s", value)
    }

    /// `+0.90 s`, `-1.20 s`; a delta that rounds to zero prints `+0.00 s`.
    static func signedSeconds(_ value: Double) -> String {
        let rounded = (value * 100).rounded() / 100
        return (rounded < 0 ? "-" : "+") + String(format: "%.2f s", abs(rounded))
    }

    /// A fraction as `+5.2 %`.
    static func signedPercent(_ fraction: Double) -> String {
        let rounded = (fraction * 1000).rounded() / 10
        return (rounded < 0 ? "-" : "+") + String(format: "%.1f %%", abs(rounded))
    }

    /// A share as `23 %` (`<1 %` for a small positive share); `n/a` when unknown.
    static func percent(_ fraction: Double?) -> String {
        guard let fraction, fraction.isFinite else { return "n/a" }
        if fraction > 0, fraction < 0.005 { return "<1 %" }
        return String(format: "%.0f %%", fraction * 100)
    }

    /// A threshold fraction as `5 %` or `2.5 %`.
    static func threshold(_ fraction: Double) -> String { String(format: "%g %%", (fraction * 1000).rounded() / 10) }

    /// `1 run`, `5 runs`.
    static func count(_ value: Int, _ noun: String) -> String { "\(value) \(noun)" + (value == 1 ? "" : "s") }

    /// `+0.90 s (+5.2 %)`; the percentage is left out when unknown, `n/a` when the delta is.
    static func deltaText(_ delta: Double?, _ fraction: Double?) -> String {
        guard let delta else { return "n/a" }
        return signedSeconds(delta) + (fraction.map { " (\(signedPercent($0)))" } ?? "")
    }

    // MARK: - Text safety

    /// Control characters (C0, DEL, C1) become spaces and runs of spaces collapse, so a crafted log line cannot add
    /// lines, markup structure or escape sequences to a report.
    static func oneLine(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        var lastSpace = false
        for scalar in text.unicodeScalars {
            let isControl = scalar.value < 0x20 || (0x7F...0x9F).contains(scalar.value)
            let value = isControl ? " " : scalar
            if value == " " {
                if lastSpace { continue }
                lastSpace = true
            } else {
                lastSpace = false
            }
            scalars.append(value)
        }
        return String(scalars).trimmingCharacters(in: .whitespaces)
    }

    /// At most `limit` characters, a cut ends in an ellipsis. Runner commands are neutralized first
    /// (`neutralizeRunnerCommands`), so the text every format prints is final before any budget is fitted.
    static func clip(_ text: String, _ limit: Int) -> String {
        let line = neutralizeRunnerCommands(oneLine(text))
        return line.count > limit ? String(line.prefix(max(0, limit - 1))) + "…" : line
    }

    /// Markdown prose and table cells: one line, `<` as an entity (text is the document's, never HTML: no tag can
    /// open), `|` escaped.
    static func markdown(_ text: String, limit: Int = 300) -> String {
        mentionSafe(clip(text, limit)).replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: "|", with: "\\|")
    }

    /// A GitHub mention: `@` not preceded by a word character, backtick, `@`, `/` or `.` (so an e-mail address is not
    /// one), then a login or `org/team`.
    private static let mention = try! NSRegularExpression(
        pattern: "(?<![\\w`@/.])@[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?(?:/[A-Za-z0-9_.-]+)?")

    private static let asciiPunctuation = Set("!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~")

    /// `@user` becomes `` `@user` `` outside code spans, so a compiler message pasted into a PR comment (or an
    /// annotation) never notifies the account it happens to name (`@MainActor`, `@available`, `@escaping` included).
    /// Scans left to right like CommonMark: a backslash escapes the punctuation after it outside a span only (inside
    /// one it is literal), a span runs from a backtick string to the next one of the same length, and an opener without
    /// a closer is plain text.
    static func mentionSafe(_ text: String) -> String {
        guard text.contains("@") else { return text }
        // An escaped backtick is a literal one, not a delimiter: set it aside (private-use scalar, restored below).
        let literal = "\u{E000}"
        let chars = Array(text)
        var out = ""
        var plain = ""
        func flush() {
            let whole = NSRange(plain.startIndex..., in: plain)
            var cursor = plain.startIndex
            for match in mention.matches(in: plain, range: whole) {
                guard let range = Range(match.range, in: plain) else { continue }
                out += plain[cursor..<range.lowerBound] + "`" + plain[range] + "`"
                cursor = range.upperBound
            }
            out += plain[cursor...]
            plain = ""
        }
        func run(_ start: Int) -> Int {
            var end = start
            while end < chars.count, chars[end] == "`" { end += 1 }
            return end - start
        }
        var index = 0
        while index < chars.count {
            let char = chars[index]
            if char == "\\", index + 1 < chars.count, asciiPunctuation.contains(chars[index + 1]) {
                plain += chars[index + 1] == "`" ? literal : String([char, chars[index + 1]])
                index += 2
            } else if char == "`" {
                let size = run(index)
                var scan = index + size
                var closer: Int?
                while scan < chars.count, closer == nil {
                    if chars[scan] == "`" {
                        let other = run(scan)
                        if other == size { closer = scan }
                        scan += other
                    } else {
                        scan += 1
                    }
                }
                if let closer {
                    flush()
                    out += String(chars[index..<(closer + size)])
                    index = closer + size
                } else {
                    plain += String(repeating: "`", count: size)
                    index += size
                }
            } else {
                plain.append(char)
                index += 1
            }
        }
        flush()
        return out.replacingOccurrences(of: literal, with: "\\`")
    }

    /// `##[` becomes `##\[`: the runner's legacy parser reads `##[command]` anywhere in a line it sees, so a diagnostic
    /// that says `##[add-mask]` must not act as one; a line that starts with `::` (the workflow-command syntax) gets a
    /// backslash first. The escaped text renders the same in markdown.
    static func neutralizeRunnerCommands(_ text: String) -> String {
        let escaped = text.replacingOccurrences(of: "##[", with: "##\\[")
        return escaped.drop(while: { $0 == " " || $0 == "\t" }).hasPrefix("::") ? "\\" + escaped : escaped
    }

    /// A code span; backticks inside become apostrophes, `|` is escaped for table cells.
    static func code(_ text: String, limit: Int = 300) -> String {
        "`" + clip(text, limit).replacingOccurrences(of: "`", with: "'").replacingOccurrences(of: "|", with: "\\|") + "`"
    }

    /// One markdown table row.
    static func row(_ cells: [String]) -> String { "| " + cells.joined(separator: " | ") + " |" }

    static func header(_ cells: [String]) -> [String] { [row(cells), row(cells.map { _ in "---" })] }

    // MARK: - Bytes

    static func bytes(_ text: String) -> Int { text.utf8.count }

    /// `64 KB` for a whole number of KiB, else `n bytes`.
    static func capText(_ cap: Int) -> String {
        cap >= 1024 && cap % 1024 == 0 ? "\(cap / 1024) KB" : "\(cap) bytes"
    }

    /// `text` cut to at most `cap` UTF-8 bytes at a scalar boundary, ending in one newline (empty for a cap below 1).
    static func clamp(_ text: String, to cap: Int) -> String {
        guard cap >= 1 else { return "" }
        if bytes(text) <= cap { return text }
        var out = ""
        var used = 0
        for scalar in text.unicodeScalars {
            let size = String(scalar).utf8.count
            if used + size > cap - 1 { break }
            out.unicodeScalars.append(scalar)
            used += size
        }
        while out.last == "\n" { out.removeLast() }
        return out + "\n"
    }

    // MARK: - Document facts

    /// A doctor document: no build, findings only (`input.layout == "project"`).
    static func isDoctor(_ document: ReportDocument) -> Bool { document.input.layout == "project" }

    /// Busy and critical-path seconds as the headline names them: the regression's current numbers (its basis), else
    /// the document's own.
    static func busy(_ document: ReportDocument) -> Double? { document.regression?.busy.current ?? document.build.busy }

    static func criticalPathSeconds(_ document: ReportDocument) -> Double? {
        document.regression?.criticalPath.current ?? document.criticalPath?.span
    }

    /// The wall the headline names: the regression's current wall (its basis), else the xcodebuild process wall, else
    /// the log span. Nil when unknown.
    static func wall(_ document: ReportDocument) -> Double? {
        document.regression?.wall.current ?? document.timing.processWall ?? document.build.span
    }

    /// `(S, high)`: the rule's evidence tag when `ruleDocs` has it, then the confidence.
    static func findingBadge(_ finding: ReportDocument.Finding, _ document: ReportDocument) -> String {
        let tag = document.ruleDocs[finding.ruleId]?.evidenceTag
        // A catalog estimate is named as such; a measured band stays in the finding line as before.
        let impact = finding.impactBand == nil || finding.impactBand == "?"
            ? finding.estimatedBand.map { "estimated \($0)" } : nil
        return [impact, tag, finding.confidence].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
    }

    /// `kind: clean; scheme: App; ...` pieces known on the build.
    static func buildKey(_ document: ReportDocument) -> [(String, String)] {
        var out: [(String, String)] = []
        let build = document.build
        if let kind = build.kind { out.append(("kind", kind)) }
        if let scheme = build.scheme { out.append(("scheme", scheme)) }
        if let configuration = build.configuration { out.append(("configuration", configuration)) }
        if let destination = build.destination { out.append(("destination", destination)) }
        if let xcode = document.xcode.value { out.append(("xcode", "\(xcode) (\(document.xcode.source ?? "inferred"))")) }
        return out
    }

    /// `repo-relative/path.swift` for a path under the workspace (`$REPO/` or `workspaceRoot + "/"`), a path that is
    /// already relative stays; nil for an absolute path outside the workspace, a home or token path, or a path that
    /// climbs out with `..`.
    static func repoRelative(_ path: String, workspaceRoot: String?) -> String? {
        var relative = path
        if relative.hasPrefix("$REPO/") {
            relative = String(relative.dropFirst("$REPO/".count))
        } else if let root = workspaceRoot, root.count > 1, relative.hasPrefix(root.hasSuffix("/") ? root : root + "/") {
            relative = String(relative.dropFirst(root.hasSuffix("/") ? root.count : root.count + 1))
        }
        while relative.hasPrefix("./") { relative = String(relative.dropFirst(2)) }
        if relative.isEmpty || relative.hasPrefix("/") || relative.hasPrefix("~") || relative.hasPrefix("$") { return nil }
        if relative.split(separator: "/").contains("..") { return nil }
        return relative
    }

    /// `text` with the repository prefix of a path cut (`$REPO/` and `workspaceRoot + "/"`), so a path in a message
    /// reads repo-relative like the `file` of its entry.
    static func repoText(_ text: String, workspaceRoot: String?) -> String {
        var out = text.replacingOccurrences(of: "$REPO/", with: "")
        if let root = workspaceRoot, root.count > 1 { out = out.replacingOccurrences(of: root.hasSuffix("/") ? root : root + "/", with: "") }
        return out
    }

    /// `path:line:col` pieces that are known.
    static func location(file: String?, line: Int?, column: Int?) -> String? {
        guard let file else { return nil }
        var text = oneLine(file)
        if let line {
            text += ":\(line)"
            if let column { text += ":\(column)" }
        }
        return text
    }

    // MARK: - Regression headline

    /// The sentence of the markdown headline and the agent BUILD line (docs/SCHEMA-v0.4.md "markdown"):
    /// `**slower** +0.90 s (+5.2 %) vs baseline (median of 5 runs, noise band 0.60 s)`.
    static func regressionSentence(_ regression: ReportDocument.Regression, reference: String = "baseline",
                                   bold: Bool = true) -> String {
        let verdict = bold ? "**\(regression.verdict)**" : regression.verdict
        let delta = regression.wall.delta.map { deltaText($0, regression.wall.deltaPct) } ?? "no wall delta"
        let band = regression.noiseBand
        if regression.verdict == "indicative" {
            let runs = band.runsBaseline == band.runsCurrent ? "\(count(band.runsBaseline, "run")) per side"
                : "\(count(band.runsBaseline, "baseline run")), \(count(band.runsCurrent, "current run"))"
            return "\(verdict) \(delta), \(runs): too few runs to tell it from noise"
        }
        let runs = regression.baseline.runs == 1 ? "1 run" : "median of \(regression.baseline.runs) runs"
        let noise = band.band.map { ", noise band \(seconds($0))" } ?? ""
        return "\(verdict) \(delta) vs \(reference) (\(runs)\(noise))"
    }

    /// `FAILED: over the 5 % threshold` when the regression failed, else nil.
    static func regressionFailure(_ regression: ReportDocument.Regression) -> String? {
        guard regression.failed else { return nil }
        guard let limit = regression.thresholdPct else { return "FAILED: over the threshold" }
        let allowance = regression.verdict == "indicative"
            ? " (plus \(threshold(regression.allowancePct)) allowance for few runs)" : ""
        return "FAILED: over the \(threshold(limit)) threshold" + allowance
    }

    // MARK: - Diagnostics

    /// `error: path:line: message (x3)` without the severity prefix when `prefix` is false.
    static func diagnosticLine(_ entry: ReportDocument.DiagnosticEntry, workspaceRoot: String?, prefix: Bool = true,
                               messageLimit: Int = 300, column: Bool = false, alwaysCount: Bool = false) -> String {
        var line = prefix ? entry.severity + ": " : ""
        let file = entry.file.map { repoRelative($0, workspaceRoot: workspaceRoot) ?? $0 }
        if let place = location(file: file, line: entry.line, column: column ? entry.column : nil) {
            line += place + ": "
        }
        return line + clip(repoText(entry.message, workspaceRoot: workspaceRoot), messageLimit) + ((entry.occurrences > 1 || alwaysCount) ? " (x\(entry.occurrences))" : "")
    }
}

// MARK: - Repo-relative paths before redaction

extension ReportDocument {
    /// The file paths and messages of diagnostics, hotspots and file rows made repo-relative (`repoRelative`,
    /// `repoText`): done on the unredacted document, because redaction rewrites the home and the repo root and the
    /// workspace prefix no longer matches afterwards (`GITHUB_WORKSPACE` need not be the working directory's repo).
    /// A path that cannot be made relative stays as it is.
    public func repoRelativized(workspaceRoot: String?) -> ReportDocument {
        var out = self
        func relative(_ path: String) -> String { FormatText.repoRelative(path, workspaceRoot: workspaceRoot) ?? path }
        out.diagnostics = diagnostics.map { entry in
            var changed = entry
            changed.file = entry.file.map(relative)
            changed.message = FormatText.repoText(entry.message, workspaceRoot: workspaceRoot)
            return changed
        }
        out.hotspots = hotspots?.map { hotspot in
            var changed = hotspot
            changed.file = relative(hotspot.file)
            return changed
        }
        out.files = files?.map { row in
            var changed = row
            changed.path = relative(row.path)
            return changed
        }
        return out
    }
}

// MARK: - Budget fitting

/// What a reporter currently shows: per-section row limits and dropped sections. A budget step changes it.
struct FitPlan {
    var limits: [String: Int] = [:]
    var off: Set<String> = []

    func limit(_ key: String, _ standard: Int) -> Int { limits[key] ?? standard }
    func shows(_ key: String) -> Bool { !off.contains(key) }
}

/// One truncation step: the words for the footer and the change it makes. A step that changes nothing is skipped.
struct FitStep {
    var label: String
    var apply: (inout FitPlan) -> Void

    static func drop(_ keys: String..., label: String) -> FitStep {
        FitStep(label: label) { plan in keys.forEach { plan.off.insert($0) } }
    }

    static func cap(_ key: String, to rows: Int, label: String) -> FitStep {
        FitStep(label: label) { plan in plan.limits[key] = min(plan.limits[key] ?? .max, rows) }
    }
}

enum Fit {
    /// Renders with the standard plan; while over `cap`, applies the steps in order (each only if it changes the
    /// output) and stops at the first rendering that fits, with the truncation line the renderer places before its
    /// footer. When every step is spent and the body is still too long, cuts at the last whole line that leaves room
    /// for the truncation line. The result is never longer than `cap` bytes.
    static func fit(cap: Int, reproduce: String, steps: [FitStep], render: (FitPlan, String?) -> String) -> String {
        var plan = FitPlan()
        var current = render(plan, nil)
        if FormatText.bytes(current) <= cap { return current }
        var applied: [String] = []
        func note() -> String {
            "_Truncated to fit \(FormatText.capText(cap)): \(applied.joined(separator: ", ")). Full detail: \(reproduce)_"
        }
        for step in steps {
            var next = plan
            step.apply(&next)
            let trial = render(next, nil)
            if trial == current { continue }
            plan = next
            current = trial
            applied.append(step.label)
            let noted = render(plan, note())
            if FormatText.bytes(noted) <= cap { return noted }
        }
        applied.append("trailing lines")
        var lines = current.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        while lines.last == "" { lines.removeLast() }
        // A cap too small for the marker plus the full note gets a shorter note, then the shortest.
        let marker = FormatText.bytes(lines.first ?? "") + 1
        let candidates = [note(), "_Truncated to fit \(FormatText.capText(cap)). Full detail: \(reproduce)_",
                          "_Truncated to fit \(FormatText.capText(cap))._"]
        let noteLine = candidates.first { marker + FormatText.bytes($0) + 1 <= cap } ?? candidates[candidates.count - 1]
        var kept: [String] = []
        var used = FormatText.bytes(noteLine) + 1
        for line in lines {
            let size = FormatText.bytes(line) + 1
            if used + size > cap { break }
            kept.append(line)
            used += size
        }
        return FormatText.clamp((kept + [noteLine]).joined(separator: "\n") + "\n", to: cap)
    }
}
