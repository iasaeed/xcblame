import ArgumentParser
import Foundation
import XcblameKit

/// Root command: subcommands, version, and the exit-code mapping (see `XcblameExit`).
@main
struct Xcblame: ParsableCommand {
    static let version = XcblameVersion.current

    static let configuration = CommandConfiguration(
        commandName: "xcblame",
        abstract: "Measure, explain and fix Xcode build time.",
        version: version,
        subcommands: [AnalyzeCommand.self, BuildCommand.self, WhyCommand.self, DoctorCommand.self, FixCommand.self,
                      VerifyCommand.self, CompareCommand.self,
                      TrendCommand.self, BaselineCommand.self, SchemaCommand.self, RulesCommand.self,
                      HistoryCommand.self, SelfTestCommand.self, VersionCommand.self])

    static func main() {
        do {
            var command = try parseAsRoot()
            try command.run()
        } catch {
            terminate(error)
        }
    }

    /// Maps errors onto xcblame's exit codes: usage problems are 2 (ArgumentParser's own code is 64), known
    /// `XcblameError`s per the table, anything unexpected is 6.
    static func terminate(_ error: Error) -> Never {
        if let code = error as? ArgumentParser.ExitCode { Foundation.exit(code.rawValue) }
        if let known = error as? XcblameError {
            writeStderr("error: \(known)")
            Foundation.exit(XcblameExit(known).rawValue)
        }
        let code = exitCode(for: error)
        let message = fullMessage(for: error)
        if code == .success {
            if !message.isEmpty { print(message) }
            Foundation.exit(0)
        }
        writeStderr(message)
        Foundation.exit(code == .validationFailure ? XcblameExit.usage.rawValue : XcblameExit.internalError.rawValue)
    }
}

struct VersionCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "version", abstract: "Print the xcblame version.")

    func run() {
        print("xcblame \(Xcblame.version) (kind table \(KindTable.v1.version))")
    }
}

func writeStderr(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}
