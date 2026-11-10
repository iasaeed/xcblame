import Foundation

/// Tool version shared by the CLI and the report `tool` block.
public enum XcblameVersion {
    public static let current = "0.6.1"
}

/// Errors the CLI maps onto exit codes (the table lives in `Sources/xcblame/ExitCode.swift`).
public enum XcblameError: Error, Sendable, Equatable, CustomStringConvertible {
    /// No reader is wired into this build for the given input (lane C ships without readers).
    case noReaderAvailable
    /// The input path (or `--model-json` file) does not exist or is unreadable.
    case logNotFound(String)
    /// The Locator found no usable build log; the message lists what was searched or found and the hint.
    case noBuildLog(String)
    /// A reader or the model decoder rejected the input.
    case readerFailure(String)
    /// Bad flag combination found after parsing.
    case usage(String)
    /// A v0.2 entry point whose body has not landed yet; the text names what is missing.
    case notImplemented(String)
    /// `doctor` (or an explicit `--project`/`--workspace`) found no `.xcworkspace`, `.xcodeproj` or `Package.swift`.
    case projectNotFound(String)
    /// A project file exists but cannot be parsed (corrupt pbxproj, unreadable workspace, xcconfig or manifest).
    case projectUnreadable(String)
    /// A report could not be made safe to write (redaction or encoding failed): nothing is written, never an
    /// unredacted file (DESIGN §3.1).
    case outputAborted(String)

    public var description: String {
        switch self {
        case .noReaderAvailable: return "no log reader is available in this build"
        case let .logNotFound(path):
            return "log not found or not readable: \(path) (pass an .xcactivitylog, an .xcresult, a DerivedData folder or a Logs/Build folder)"
        case let .noBuildLog(why): return why
        case let .readerFailure(why): return "could not read the build log: \(why)"
        case let .usage(why): return why
        case let .notImplemented(what): return "not implemented in this build: \(what)"
        case let .projectNotFound(why): return "project not found: \(why)"
        case let .projectUnreadable(why): return "could not read the project: \(why)"
        case let .outputAborted(why): return "\(why); no report was written"
        }
    }
}
