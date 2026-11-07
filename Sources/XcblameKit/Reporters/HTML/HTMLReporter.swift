import Foundation

/// The one-file HTML report (DESIGN §8.2): the embedded template with the report document as one JSON blob.
public enum HTMLReporter {
    /// Default `--max-report-bytes` for html: the whole file, template included (§8.2.3).
    public static let defaultMaxBytes = 8_000_000

    public struct Options: Sendable {
        /// Informational: the CLI runs the Redactor before rendering, and the page trusts `document.redacted`.
        public var redact: Bool
        public var maxBytes: Int
        public var title: String

        public init(redact: Bool, maxBytes: Int = HTMLReporter.defaultMaxBytes, title: String) {
            self.redact = redact
            self.maxBytes = maxBytes
            self.title = title
        }
    }

    static let dataPlaceholder = "{{DATA}}"

    /// Budget pass, then the blob, then the placeholders; `{{DATA}}` is substituted last and only once, so text in
    /// the data that looks like a placeholder is never replaced. Same input → byte-identical output.
    public static func render(_ document: ReportDocument, taskIndex: TaskIndex?, options: Options) throws -> Data {
        try renderReport(document, taskIndex: taskIndex, options: options).data
    }

    /// As `render`, plus the embedded document: truncated by the budget pass, with V13 measured on the final page
    /// against `maxBytes` (template included). V13 passes when the page fits and warns when even the last resort
    /// does not; size never fails (§8.2.3), the caller warns on stderr.
    public static func renderReport(_ document: ReportDocument, taskIndex: TaskIndex?,
                                    options: Options) throws -> (data: Data, document: ReportDocument) {
        let page = filledTemplate(document, title: options.title)
        guard let range = page.range(of: dataPlaceholder) else {
            throw XcblameError.notImplemented("report template has no \(dataPlaceholder) placeholder")
        }
        let templateBytes = page.utf8.count - dataPlaceholder.utf8.count
        /// The page with V13 measured on itself: rendered once with the size before the V13 line, then once more
        /// with the size that page came out at (the second pass only changes when the digit count does).
        func rendered(_ measured: ReportDocument, _ taskIndex: TaskIndex?) throws -> (data: Data, document: ReportDocument) {
            func pass(v13 size: Int) throws -> (data: Data, document: ReportDocument) {
                var document = measured
                document.validation.checks = document.validation.checks.map { check in
                    guard check.id == "V13" else { return check }
                    let steps = document.truncation.steps.map(\.step)
                    let truncated = steps.isEmpty ? "" : "; truncated: " + steps.joined(separator: ", ")
                    return size <= options.maxBytes
                        ? ReportDocument.Check(id: check.id, title: check.title, status: "pass",
                                               detail: "\(size) of \(options.maxBytes) bytes (html, template included)\(truncated)")
                        : ReportDocument.Check(id: check.id, title: check.title, status: "warn",
                                               detail: "html is \(size) bytes, over the \(options.maxBytes)-byte cap even "
                                                   + "after the last resort; written anyway\(truncated)")
                }
                var out = Data(page[..<range.lowerBound].utf8)
                out.append(Data(try dataBlob(document, taskIndex: taskIndex).utf8))
                out.append(Data(page[range.upperBound...].utf8))
                return (out, document)
            }
            let first = try pass(v13: try dataBlob(measured, taskIndex: taskIndex).utf8.count + templateBytes)
            return try pass(v13: first.data.count)
        }
        // The whole page, V13 line included, fits: no truncation at all.
        let whole = try rendered(document, taskIndex)
        if whole.data.count <= options.maxBytes { return whole }
        // Otherwise the budget leaves room for the final V13 line (its detail and the step names stay well under
        // the reserve), so a page that comes out of it fitting the reduced budget fits the cap.
        var document = document
        var taskIndex = taskIndex
        ReportBudget.apply(&document, taskIndex: &taskIndex, maxBytes: options.maxBytes - v13Reserve,
                           templateBytes: templateBytes)
        return try rendered(document, taskIndex)
    }

    /// Bytes the budget pass keeps free for the html V13 line written after it.
    static let v13Reserve = 512

    /// The template with every placeholder except `{{DATA}}` filled with HTML-escaped text.
    static func filledTemplate(_ document: ReportDocument, title: String) -> String {
        filledTemplate(toolVersion: document.tool.version, generatedAt: document.generatedAt, title: title)
    }

    /// Same for documents that are not a `ReportDocument` (compare and trend, docs/SCHEMA-v0.4.md).
    static func filledTemplate(toolVersion: String, generatedAt: Date, title: String) -> String {
        let generated = ISO8601DateFormatter().string(from: generatedAt)
        return ReportTemplate.html
            .replacingOccurrences(of: "{{TITLE}}", with: escapeHTML(title))
            .replacingOccurrences(of: "{{TOOL_VERSION}}", with: escapeHTML(toolVersion))
            .replacingOccurrences(of: "{{GENERATED_AT}}", with: escapeHTML(generated))
    }

    /// The `#xcblame-data` content: exactly `JSONReporter.render(document)` with `taskIndex` spliced in as one more
    /// top-level member at its sorted position, then escaped for script data. Without `taskIndex` and without
    /// characters that need escaping it is byte-equal to `--format json` (§8.2.1 principle 3).
    // ponytail: the document stays pretty-printed (JSONReporter's format, for byte parity) while `taskIndex` is
    // compact, since a 50k-task index pretty-printed is one number per line. Revisit if the parity rule moves to
    // minified JSON as DESIGN §8.2.5 step 4 says.
    public static func dataBlob(_ document: ReportDocument, taskIndex: TaskIndex?) throws -> String {
        var json = try JSONReporter.renderString(document)
        if let taskIndex {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let index = String(decoding: try encoder.encode(taskIndex), as: UTF8.self)
            json = splice(member: "taskIndex", value: index, into: json)
        }
        return escapeScriptData(json)
    }

    /// Inserts `"name" : value` among the top-level members of a pretty-printed, key-sorted object. Top-level keys
    /// are the lines that start with exactly two spaces and a quote (string values never hold a raw newline).
    static func splice(member name: String, value: String, into json: String) -> String {
        var lines = json.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let member = "  \"\(name)\" : \(value)"
        func key(_ line: String) -> String? {
            guard line.hasPrefix("  \""), !line.hasPrefix("   ") else { return nil }
            let body = line.dropFirst(3)
            return String(body[..<(body.firstIndex(of: "\"") ?? body.endIndex)])
        }
        if let next = lines.indices.first(where: { key(lines[$0]).map { $0 > name } ?? false }) {
            lines.insert(member + ",", at: next)
        } else if let closing = lines.lastIndex(of: "}") {
            if closing > 0, !lines[closing - 1].hasSuffix("{") { lines[closing - 1] += "," }
            lines.insert(member, at: closing)
        }
        return lines.joined(separator: "\n")
    }

    /// Keeps the JSON valid while making it inert inside `<script>`: `</` → `<\/`, `<!--` → `<!--`,
    /// U+2028/U+2029 → ` `/` `. `<` only occurs inside JSON strings, where all of these are legal escapes.
    static func escapeScriptData(_ json: String) -> String {
        guard json.contains("<") || json.contains("\u{2028}") || json.contains("\u{2029}") else { return json }
        return json.replacingOccurrences(of: "<!--", with: "\\u003c!--")
            .replacingOccurrences(of: "</", with: "<\\/")
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }

    static func escapeHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}
