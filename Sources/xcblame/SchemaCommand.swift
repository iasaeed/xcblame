import ArgumentParser
import Foundation
import XcblameKit

/// `xcblame schema [--version n] [--document …]` (DESIGN §3.2; docs/SCHEMA-v0.4.md "JSON Schema"; v0.6 adds `fixplan`
/// and `verify`, docs/SCHEMA-v0.6.md).
struct SchemaCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "schema",
        abstract: "Print the JSON Schema (draft 2020-12) of the report, compare, trend, baseline, fix plan or verify document.")

    enum SchemaDocument: String, ExpressibleByArgument, CaseIterable {
        case report, compare, trend, baseline, fixplan, verify, all
    }

    @Option(help: "Schema major version (the n of xcblame.report/n). Only 1 exists.") var version: Int = 1
    @Option(help: "Which document: report (default), compare, trend, baseline, fixplan, verify or all.") var document: SchemaDocument = .report

    func validate() throws {
        if !JSONSchema.versions.contains(version) {
            throw ValidationError("--version \(version) is unknown (known: "
                + JSONSchema.versions.map(String.init).joined(separator: ", ") + ")")
        }
    }

    func run() throws {
        // v0.4 lane A (begin)
        let text = try JSONSchema.render(JSONSchema.Document(rawValue: document.rawValue) ?? .report, version: version)
        FileHandle.standardOutput.write(Data(text.utf8))
        // v0.4 lane A (end)
    }
}
