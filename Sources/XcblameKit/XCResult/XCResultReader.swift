import Foundation

/// Reads `xcrun xcresulttool get log --type build` JSON into a `RawLog` (DESIGN §5.7).
///
/// Section object: `{title, domainType, duration (s), startTime (Unix s), result, attachments[], messages[],
/// subsections[], commandInvocationDetails{commandDetails, emittedOutput, exitCode}, location}`. Every key is
/// optional and unknown keys are ignored. Severity comes from the message `type` string, never from `category`.
public enum XCResultReader {
    public enum ReadError: Error, LocalizedError, Equatable {
        case invalidJSON(String)
        case notASection
        case toolFailed(status: Int32, stderr: String)
        case toolTimedOut(seconds: Int)
        case toolUnavailable

        public var errorDescription: String? {
            switch self {
            case .invalidJSON(let detail): return "xcresult build log is not valid JSON: \(detail)"
            case .notASection: return "xcresult build log root is not a section object"
            case .toolFailed(let status, let stderr):
                return "xcresulttool exited with status \(status): \(stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
            case .toolTimedOut(let seconds): return "xcresulttool did not finish within \(seconds) s"
            case .toolUnavailable: return "could not launch `xcrun xcresulttool`"
            }
        }
    }

    public static let toolTimeout: TimeInterval = 120

    /// `xcrun xcresulttool get log --path <bundle> --type build`, 120 s timeout, stderr kept for the error.
    public static func read(resultBundle: URL) throws -> RawLog {
        let argv = ["xcrun", "xcresulttool", "get", "log", "--path", resultBundle.path, "--type", "build"]
        guard let out = runProcess(argv, timeout: toolTimeout) else { throw ReadError.toolUnavailable }
        if out.timedOut { throw ReadError.toolTimedOut(seconds: Int(toolTimeout)) }
        guard out.exitStatus == 0 else {
            throw ReadError.toolFailed(status: out.exitStatus, stderr: out.stderrString)
        }
        return try read(jsonData: out.stdout)
    }

    public static func read(jsonData: Data) throws -> RawLog {
        // ponytail: streaming scanner when a 1 GB log shows up (DESIGN §5.7)
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: jsonData)
        } catch {
            throw ReadError.invalidJSON(error.localizedDescription)
        }
        guard let root = object as? [String: Any] else { throw ReadError.notASection }
        var mapper = Mapper()
        let section = mapper.section(root).section
        return RawLog(formatVersion: nil, layout: .xcresult, root: section, decodeWarnings: mapper.warnings)
    }

    // MARK: - Mapping

    private struct Mapper {
        var warnings: [DecodeWarning] = []

        /// A section without `startTime` (the root) starts at its earliest child; `hasStart` says whether it is real.
        mutating func section(_ json: [String: Any]) -> (section: RawSection, hasStart: Bool) {
            let durationValue = (json["duration"] as? NSNumber)?.doubleValue
            let duration = durationValue ?? 0
            var children: [RawSection] = []
            var childStarts: [Double] = []
            for case let child as [String: Any] in (json["subsections"] as? [Any]) ?? [] {
                let mapped = section(child)
                children.append(mapped.section)
                if mapped.hasStart { childStarts.append(mapped.section.start) }
            }
            let ownStart = (json["startTime"] as? NSNumber)?.doubleValue
            let start = ownStart ?? childStarts.min() ?? 0
            let details = json["commandInvocationDetails"] as? [String: Any]
            let built = RawSection(
                title: json["title"] as? String ?? "",
                domainType: json["domainType"] as? String,
                commandDetails: details?["commandDetails"] as? String,
                start: start, end: start + duration,
                resultCode: (details?["exitCode"] as? NSNumber)?.intValue,
                emittedOutput: details?["emittedOutput"] as? String,
                messages: messages(json["messages"]),
                attachments: attachments(json["attachments"]),
                subsections: children,
                location: location(json["location"]),
                timingMissing: (ownStart == nil && childStarts.isEmpty) || durationValue == nil)
            return (built, ownStart != nil || !childStarts.isEmpty)
        }

        func messages(_ value: Any?) -> [RawMessage] {
            var result: [RawMessage] = []
            for case let item as [String: Any] in (value as? [Any]) ?? [] {
                result.append(RawMessage(
                    title: item["title"] as? String ?? "",
                    type: item["type"] as? String,
                    categoryIdent: item["category"] as? String,
                    location: location(item["location"]),
                    // `annotations[]` carry notes / fix-its as `{title, location}`; same shape, no `type`.
                    submessages: messages(item["annotations"])))
            }
            return result
        }

        mutating func attachments(_ value: Any?) -> [RawAttachment] {
            var result: [RawAttachment] = []
            for case let item as [String: Any] in (value as? [Any]) ?? [] {
                let identifier = item["uniformTypeIdentifier"] as? String ?? ""
                let payload: Data?
                switch item["data"] {
                case let text as String: payload = Data(text.utf8)
                case let other? where JSONSerialization.isValidJSONObject(other):
                    payload = try? JSONSerialization.data(withJSONObject: other)
                default: payload = nil
                }
                guard let payload else {
                    warnings.append(DecodeWarning(kind: .invalidAttachment, detail: "attachment \(identifier) has no usable data"))
                    continue
                }
                result.append(RawAttachment(
                    identifier: identifier,
                    majorVersion: (item["typeMajorVersion"] as? NSNumber)?.intValue,
                    minorVersion: (item["typeMinorVersion"] as? NSNumber)?.intValue,
                    data: payload))
            }
            return result
        }

        /// `{concreteTypeName, url}`; the URL fragment carries `StartingLineNumber=..&StartingColumnNumber=..` (0-based).
        func location(_ value: Any?) -> RawLocation? {
            guard let json = value as? [String: Any], let url = json["url"] as? String, !url.isEmpty else { return nil }
            let parts = url.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
            var result = RawLocation(file: String(parts[0]), numberBase: 0)
            guard parts.count == 2 else { return result }
            for pair in parts[1].split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1)
                guard kv.count == 2, let number = Int(kv[1]) else { continue }
                switch kv[0] {
                case "StartingLineNumber": result.startLine = number
                case "StartingColumnNumber": result.startColumn = number
                case "EndingLineNumber": result.endLine = number
                case "EndingColumnNumber": result.endColumn = number
                default: break
                }
            }
            return result
        }
    }
}
