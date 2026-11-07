import XcblameKit

/// xcblame process exit codes, the one table for every subcommand. Numbering and meanings follow DESIGN §8.4.
enum XcblameExit: Int32 {
    /// Success.
    case ok = 0
    /// xcblame internal error or analysis unavailable: a validation check failed so the
    /// numbers it guards are withheld in the report; `doctor`: a project file exists but cannot be parsed.
    case internalError = 1
    /// Usage error (bad or unknown flags, conflicting arguments).
    case usage = 2
    /// `--fail-if-slower` (`analyze`, `build`) or `compare --threshold` exceeded (`regression.failed`, DESIGN §6.10).
    case failIfSlower = 3
    /// `doctor --fail-on <severity>`: a finding at or above that severity is present.
    case failOnHit = 4
    /// Log, result bundle or `--model-json` file not found or not readable (including a reader rejecting it, and a
    /// directory with no usable build log: candidates and hint are printed); `doctor`: no project found.
    case logNotFound = 5
    /// `verify` aborted (dirty tree, battery, thermal, timeout, broken baseline build; docs/SCHEMA-v0.6.md).
    case verifyAborted = 6

    init(_ error: XcblameError) {
        switch error {
        case .logNotFound, .readerFailure, .noBuildLog, .projectNotFound: self = .logNotFound
        case .noReaderAvailable, .notImplemented, .projectUnreadable, .outputAborted: self = .internalError
        case .usage: self = .usage
        }
    }
}
