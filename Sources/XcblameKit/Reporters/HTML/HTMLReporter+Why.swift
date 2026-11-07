import Foundation

// v0.5 lane B (docs/SCHEMA-v0.5.md "HTML views"): `why --format html`.
extension HTMLReporter {
    /// The report page of a `why` run: the shared template shows sections 1, 7, 2, 3, 10 for a document whose
    /// `incremental.procedure` is set (DESIGN §8.2.4), and the whole report otherwise (`why --log`). Same budget pass
    /// and V13 handling as `renderReport`; the title defaults to `xcblame why`.
    public static func renderWhy(_ document: ReportDocument, taskIndex: TaskIndex?,
                                 options: Options) throws -> (data: Data, document: ReportDocument) {
        var options = options
        if options.title.isEmpty || options.title == "xcblame report" { options.title = "xcblame why" }
        return try renderReport(document, taskIndex: taskIndex, options: options)
    }
}
