import Foundation

/// One log entry of a `LogStoreManifest.plist` (DESIGN §5.2).
public struct ManifestEntry: Sendable, Equatable {
    public var fileName: String
    public var className: String?
    public var domainType: String?
    public var schemeName: String?
    public var containerName: String?
    /// Display only; never used for selection.
    public var title: String?
    /// Unix epoch seconds (the plist stores the 2001 epoch).
    public var started: Double?
    public var stopped: Double?
    /// `primaryObservable.highLevelStatus`: S, W or E.
    public var status: String?
    public var errorCount: Int?
    public var warningCount: Int?
    public var analyzerIssueCount: Int?
}

public struct LogStoreManifest: Sendable, Equatable {
    public var logFormatVersion: Int?
    public var entries: [ManifestEntry]
}

public enum ManifestReader {
    public enum ReadError: Error, LocalizedError, Equatable {
        case unreadable(String)
        case notAManifest(String)

        public var errorDescription: String? {
            switch self {
            case .unreadable(let detail): return "cannot read LogStoreManifest.plist: \(detail)"
            case .notAManifest(let path): return "\(path) is not a LogStoreManifest property list"
            }
        }
    }

    public static let fileName = "LogStoreManifest.plist"

    public static func read(url: URL) throws -> LogStoreManifest {
        let data: Data
        do { data = try Data(contentsOf: url) } catch { throw ReadError.unreadable(error.localizedDescription) }
        return try parse(data: data, source: url.path)
    }

    public static func parse(data: Data, source: String = "plist") throws -> LogStoreManifest {
        let object: Any
        do {
            object = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        } catch {
            throw ReadError.unreadable(error.localizedDescription)
        }
        guard let root = object as? [String: Any], let logs = root["logs"] as? [String: Any] else {
            throw ReadError.notAManifest(source)
        }
        var entries: [ManifestEntry] = []
        for (key, value) in logs {
            guard let log = value as? [String: Any] else { continue }
            let observable = log["primaryObservable"] as? [String: Any]
            entries.append(ManifestEntry(
                fileName: log["fileName"] as? String ?? key + ".xcactivitylog",
                className: log["className"] as? String,
                domainType: log["domainType"] as? String,
                schemeName: log["schemeIdentifier-schemeName"] as? String,
                containerName: log["schemeIdentifier-containerName"] as? String,
                title: log["title"] as? String,
                started: unixTime(log["timeStartedRecording"]),
                stopped: unixTime(log["timeStoppedRecording"]),
                status: observable?["highLevelStatus"] as? String,
                errorCount: (observable?["totalNumberOfErrors"] as? NSNumber)?.intValue,
                warningCount: (observable?["totalNumberOfWarnings"] as? NSNumber)?.intValue,
                analyzerIssueCount: (observable?["totalNumberOfAnalyzerIssues"] as? NSNumber)?.intValue))
        }
        // Dictionary order is arbitrary; keep the result deterministic.
        entries.sort { $0.fileName < $1.fileName }
        return LogStoreManifest(logFormatVersion: (root["logFormatVersion"] as? NSNumber)?.intValue, entries: entries)
    }

    private static func unixTime(_ value: Any?) -> Double? {
        // The plist stores seconds since 2001-01-01 as a real; a Date is accepted too.
        if let number = value as? NSNumber { return number.doubleValue + BuildModelBuilder.appleEpochOffset }
        if let date = value as? Date { return date.timeIntervalSince1970 }
        return nil
    }
}
