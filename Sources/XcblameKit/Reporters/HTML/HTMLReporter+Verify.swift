import Foundation

// v0.6 lane C (docs/SCHEMA-v0.6.md "HTML"): the one-file pages of `verify --format html` (DESIGN §8.2.4 #13) and
// `fix --format html` (the fix-plan view, section 6), each embedding its document's JSON like `renderTrend`.
extension HTMLReporter {
    /// The template with the pretty `VerifyDocument` JSON as `#xcblame-data`, byte-equal to `verify --format json` apart
    /// from the script-data escapes. No budget pass: a verify document is a few KB. The caller redacts first.
    public static func renderVerify(_ verify: VerifyDocument, options: Options) throws -> Data {
        try page(json: try JSONReporter.render(verify), toolVersion: verify.tool.version, generatedAt: verify.generatedAt,
                 options: options)
    }

    /// The fix-plan view: the template with the `FixPlanDocument` JSON, byte-equal to `fix --format json`.
    public static func renderFixPlan(_ plan: FixPlanDocument, options: Options) throws -> Data {
        try page(json: try JSONReporter.render(plan), toolVersion: plan.tool.version, generatedAt: plan.generatedAt,
                 options: options)
    }

    private static func page(json: Data, toolVersion: String, generatedAt: Date, options: Options) throws -> Data {
        let page = filledTemplate(toolVersion: toolVersion, generatedAt: generatedAt, title: options.title)
        guard let range = page.range(of: dataPlaceholder) else {
            throw XcblameError.notImplemented("report template has no \(dataPlaceholder) placeholder")
        }
        var out = Data(page[..<range.lowerBound].utf8)
        out.append(Data(escapeScriptData(String(decoding: json, as: UTF8.self)).utf8))
        out.append(Data(page[range.upperBound...].utf8))
        return out
    }
}
