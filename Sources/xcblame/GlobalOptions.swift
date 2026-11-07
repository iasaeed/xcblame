import ArgumentParser
import Foundation
import XcblameKit

enum OutputFormat: String, ExpressibleByArgument, CaseIterable {
    case text, json, html
    /// v0.4 (docs/SCHEMA-v0.4.md "Formats"): PR comment, PR comment plus GitHub annotations, JUnit XML, agent summary.
    case markdown, github, junit, agent

    /// Size cap and redact default of this format (`ReportBudget.Format`).
    var budgetFormat: ReportBudget.Format { ReportBudget.Format(rawValue: rawValue) ?? .text }

    /// True for the formats whose size V13 checks on the serialized JSON (`text` renders from the same document).
    /// html and the four v0.4 text formats are measured on their own output instead.
    var measuresJSONSize: Bool { self == .text || self == .json }
}

/// `--top <n>|all`; `all` is `Int.max`.
struct TopCount: ExpressibleByArgument {
    var value: Int

    init(_ value: Int) { self.value = value }

    init?(argument: String) {
        if argument == "all" { value = .max } else if let number = Int(argument) { value = number } else { return nil }
    }
}

/// Global flags (DESIGN §3.1), mixed into every report-producing subcommand.
struct GlobalOptions: ParsableArguments {
    @Option(help: "Output format: text, json, html, markdown, github, junit or agent (default: text; json when stdout is not a terminal and CI=true). html always goes to a file.")
    var format: OutputFormat?
    @Option(name: [.short, .long], help: "Write the report to this file; stdout keeps a one-line summary.",
            completion: .file())
    var output: String?
    @Flag(help: "Open an html report after writing it (ignored with a note when CI=true).") var open = false
    @Option(help: "App to open the html report with (default: the default browser).") var browser: String?
    @Flag(help: "Never use ANSI colors (NO_COLOR is honoured too).") var noColor = false
    @Flag(name: .shortAndLong, help: "No notes on stderr; warnings and errors still print.") var quiet = false
    @Flag(name: .shortAndLong, help: "Print decode warnings and extra detail on stderr.") var verbose = false
    @Flag(inversion: .prefixedNo,
          help: "Replace home, user, host, repo root and DerivedData hash with tokens (default: on for html, markdown, github and agent; off otherwise).")
    var redact: Bool?
    @Option(help: "Rows per ranked table (targets, top tasks), or all (default: 15; all for html and junit).") var top: TopCount?

    func validate() throws {
        if let top, top.value < 1 { throw ValidationError("--top must be at least 1 or all") }
    }

    var resolvedFormat: OutputFormat {
        if let format { return format }
        let env = ProcessInfo.processInfo.environment
        return !Terminal.stdoutIsTTY && env["CI"] == "true" ? .json : .text
    }

    var resolvedRedact: Bool { redact ?? resolvedFormat.budgetFormat.redactsByDefault }

    /// `Int.max` means all rows.
    /// html and junit default to all: junit draws no table, and its target budgets need every target's row.
    var resolvedTop: Int { top?.value ?? ([.html, .junit].contains(resolvedFormat) ? .max : 15) }

    var isCI: Bool { ProcessInfo.processInfo.environment["CI"] == "true" }

    /// Colors only for text on an interactive terminal, with `--no-color` and `NO_COLOR` both unset.
    var useColors: Bool {
        resolvedFormat == .text && output == nil && Terminal.stdoutIsTTY && !noColor
            && ProcessInfo.processInfo.environment["NO_COLOR"] == nil
    }
}

enum Terminal {
    static var stdoutIsTTY: Bool { isatty(STDOUT_FILENO) != 0 }
}
