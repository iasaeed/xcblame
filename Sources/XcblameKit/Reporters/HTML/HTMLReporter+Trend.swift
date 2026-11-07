import Foundation

extension HTMLReporter {
    /// The one-file HTML of `trend --format html` (DESIGN §8.2.4 #12; docs/SCHEMA-v0.4.md "HTML views"): the template
    /// with the pretty-printed `TrendDocument` JSON as `#xcblame-data`, byte-equal to `trend --format json` apart from
    /// the script-data escapes. No task indexes. The caller redacts first (`Redactor.redact(_:context:)`) when asked.
    ///
    /// There is no budget pass: a trend document holds one small point per history entry, and retention keeps the
    /// history at 200 entries, so it stays far below `options.maxBytes`. A page that still exceeds it is returned as
    /// is and the caller warns (size never fails, §8.2.3).
    public static func renderTrend(_ document: TrendDocument, options: Options) throws -> Data {
        let page = filledTemplate(toolVersion: document.tool.version, generatedAt: document.generatedAt,
                                  title: options.title)
        guard let range = page.range(of: dataPlaceholder) else {
            throw XcblameError.notImplemented("report template has no \(dataPlaceholder) placeholder")
        }
        let blob = escapeScriptData(String(decoding: try Trend.renderJSON(document), as: UTF8.self))
        var out = Data(page[..<range.lowerBound].utf8)
        out.append(Data(blob.utf8))
        out.append(Data(page[range.upperBound...].utf8))
        return out
    }
}
