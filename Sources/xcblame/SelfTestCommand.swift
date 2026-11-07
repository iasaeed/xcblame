import ArgumentParser
import XcblameKit

struct SelfTestCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "selftest",
        abstract: "Run analysis, validation and both reporters on a synthetic model and check their invariants.")

    @Flag(name: .shortAndLong, help: "Print nothing when the self-test passes.") var quiet = false

    func run() throws {
        let outcome = SelfTest.run()
        if outcome.passed {
            if !quiet { print(outcome.summary) }
        } else {
            print(outcome.summary)
            throw ArgumentParser.ExitCode(XcblameExit.internalError.rawValue)
        }
    }
}
