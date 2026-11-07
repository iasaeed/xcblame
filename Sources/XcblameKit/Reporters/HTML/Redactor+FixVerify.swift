import Foundation

// v0.6 lane C (docs/SCHEMA-v0.6.md "General rules"): the Redactor's walk over the fix plan and verify documents, and
// their `prepareForOutput` step. Same string rules and round trip as the report (`Redactor.roundTrip`), `redacted` set.
extension Redactor {
    public static func redact(_ document: FixPlanDocument, context: Context) throws -> FixPlanDocument {
        var marked = document
        marked.redacted = true
        return try roundTrip(marked, context: context)
    }

    public static func redact(_ document: VerifyDocument, context: Context) throws -> VerifyDocument {
        var marked = document
        marked.redacted = true
        return try roundTrip(marked, context: context)
    }
}

extension ReportPipeline {
    public static func prepareForOutput(_ document: FixPlanDocument, redact: Bool,
                                        context: @autoclosure () -> Redactor.Context = .current()) throws -> FixPlanDocument {
        redact ? try Redactor.redact(document, context: context()) : try DocumentSanitizer.sanitize(document)
    }

    public static func prepareForOutput(_ document: VerifyDocument, redact: Bool,
                                        context: @autoclosure () -> Redactor.Context = .current()) throws -> VerifyDocument {
        redact ? try Redactor.redact(document, context: context()) : try DocumentSanitizer.sanitize(document)
    }
}
