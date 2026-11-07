import Foundation

// v0.6 (docs/SCHEMA-v0.6.md): `fix --format json` and `verify --format json` print the document as stored, with the
// report's encoder (sorted keys, ISO-8601 dates). Lane C owns this file.
extension JSONReporter {
    public static func render(_ plan: FixPlanDocument) throws -> Data {
        try encoder().encode(plan) + Data("\n".utf8)
    }

    public static func render(_ verify: VerifyDocument) throws -> Data {
        try encoder().encode(verify) + Data("\n".utf8)
    }
}
