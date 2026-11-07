import Foundation
import XcblameKit

/// Reads a saved `--format json` report for re-rendering (`analyze report.json --format html`, DESIGN §8.2.5).
/// Unknown keys are ignored; `@Null` members decode as nil.
func loadSavedReport(at url: URL) throws -> ReportDocument {
    do {
        return try JSONReporter.decoder().decode(ReportDocument.self, from: Data(contentsOf: url))
    } catch {
        throw SavedReportError(path: url.path, reason: describe(error))
    }
}

/// A saved report that does not decode; the CLI prints it and exits 1.
struct SavedReportError: Error, CustomStringConvertible {
    var path: String
    var reason: String

    var description: String {
        "re-rendering a saved JSON report failed: \(path) is not a complete xcblame.report/1 document (\(reason))"
    }
}

private func describe(_ error: Error) -> String {
    switch error {
    case let DecodingError.keyNotFound(key, context):
        return "missing \((context.codingPath + [key]).map(\.stringValue).joined(separator: "."))"
    case let DecodingError.typeMismatch(_, context), let DecodingError.valueNotFound(_, context),
         let DecodingError.dataCorrupted(context):
        return "\(context.codingPath.map(\.stringValue).joined(separator: ".")): \(context.debugDescription)"
    default:
        return "\(error)"
    }
}
