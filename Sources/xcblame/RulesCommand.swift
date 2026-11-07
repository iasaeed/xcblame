import ArgumentParser
import Foundation
import XcblameKit

struct RulesCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rules", abstract: "The rule catalog: list rules or explain one.",
        subcommands: [List.self, Explain.self])

    static let emptyCatalog = "no rules in this build"

    static func json<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try JSONReporter.encoder().encode(value), as: UTF8.self)
    }

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "list", abstract: "List the rules.")

        @Option(help: "Only these categories, comma-separated: set, src, graph, phase, dep, env, ci, dyn.")
        var category: String?
        @Flag(help: "Print the rule specs as JSON.") var json = false

        func validate() throws { _ = try parseCategories(category) }

        func run() throws {
            let categories = try parseCategories(category)
            let specs = RuleCatalog.all.filter { categories?.contains($0.category) ?? true }
            if json {
                print(try RulesCommand.json(specs))
                return
            }
            guard !RuleCatalog.all.isEmpty else {
                print(RulesCommand.emptyCatalog)
                return
            }
            print(RuleCatalog.listTable(specs), terminator: "")
            print("\(specs.count) of \(RuleCatalog.all.count) rules · xcblame rules explain <id>")
        }
    }

    struct Explain: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "explain", abstract: "Explain one rule.")

        @Argument(help: "Rule id, e.g. SET-001.") var id: String
        @Flag(help: "Print the rule spec as JSON.") var json = false

        func run() throws {
            guard let spec = RuleCatalog.spec(id) else {
                throw XcblameError.usage(RuleCatalog.all.isEmpty ? RulesCommand.emptyCatalog
                    : "unknown rule \(id) (xcblame rules list shows the ids)")
            }
            if json { print(try RulesCommand.json(spec)) } else { print(spec.explainText, terminator: "") }
        }
    }
}
