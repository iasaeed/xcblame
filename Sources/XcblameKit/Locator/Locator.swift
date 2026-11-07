import Foundation

/// A build log that passed the manifest filter (domain + class family). Never chosen by title.
public struct LogCandidate: Sendable, Equatable {
    public var url: URL
    public var entry: ManifestEntry
    /// File modification time; nil when the file is gone.
    public var modified: Date?
}

/// Manifest entries that were not candidates, with the reason, for `--list` and error output.
public struct RejectedEntry: Sendable, Equatable {
    public var fileName: String
    public var className: String?
    public var domainType: String?
    public var reason: String
}

/// Result of scanning one `Logs/Build` directory.
public struct CandidateListing: Sendable, Equatable {
    public var buildDir: URL
    public var formatVersion: Int?
    /// Newest first: `timeStartedRecording` descending, file mtime descending as tiebreaker. Index 0 is the default.
    public var candidates: [LogCandidate]
    public var rejected: [RejectedEntry]
    /// Why `candidates` is empty (nil when it is not).
    public var emptyReason: String?
}

public enum LocatorError: Error, LocalizedError, Equatable {
    case noBuildLogs(searched: [String], reason: String)
    case indexOutOfRange(index: Int, count: Int)
    case noConfirmedLog(checked: Int)

    public var errorDescription: String? {
        switch self {
        case .noBuildLogs(let searched, let reason):
            var lines = ["no build log found: \(reason)"]
            if !searched.isEmpty { lines.append("searched: " + searched.joined(separator: ", ")) }
            lines.append(Locator.noLogHint)
            return lines.joined(separator: "\n")
        case .indexOutOfRange(let index, let count):
            return "--index \(index) is out of range: \(count) candidate build log(s), 0 is the newest"
        case .noConfirmedLog(let checked):
            return "none of the \(checked) candidate build log(s) contains an executed build task "
                + "(only clean or planning steps); pass --index to pick one anyway"
        }
    }
}

public enum Locator {
    /// Shown whenever no build log exists (DESIGN §5.2, [MV-16]).
    public static let noLogHint =
        "xcodebuild may not write an activity log without -resultBundlePath; run it through `xcblame build -- ...`"

    public static let buildLogDomain = "Xcode.IDEActivityLogDomainType.BuildLog"

    /// Manifest classes that hold a build log. xcodebuild writes `IDECommandLineBuildLog`; the IDE writes the
    /// `IDEActivityLogSection` family ([MV-15]: exact names to be confirmed on more IDE logs).
    public static let buildLogClassFamily: Set<String> = [
        "IDECommandLineBuildLog", "IDEActivityLogSection", "IDEActivityLogMajorGroupSection",
    ]

    /// Lists build-log candidates in `buildDir` (a `DerivedData/<Name>-<hash>/Logs/Build` directory).
    public static func candidates(in buildDir: URL, fileManager fm: FileManager = .default) -> CandidateListing {
        var listing = CandidateListing(buildDir: buildDir, formatVersion: nil, candidates: [], rejected: [],
                                       emptyReason: nil)
        let manifestURL = buildDir.appendingPathComponent(ManifestReader.fileName)
        guard fm.fileExists(atPath: manifestURL.path) else {
            listing.emptyReason = fm.fileExists(atPath: buildDir.path)
                ? "\(buildDir.path) has no \(ManifestReader.fileName)" : "\(buildDir.path) does not exist"
            return listing
        }
        let manifest: LogStoreManifest
        do { manifest = try ManifestReader.read(url: manifestURL) } catch {
            listing.emptyReason = error.localizedDescription
            return listing
        }
        listing.formatVersion = manifest.logFormatVersion

        for entry in manifest.entries {
            guard entry.domainType == buildLogDomain else {
                listing.rejected.append(reject(entry, "domainType is \(entry.domainType ?? "missing"), not BuildLog"))
                continue
            }
            guard let className = entry.className, buildLogClassFamily.contains(className) else {
                listing.rejected.append(reject(entry, "className \(entry.className ?? "missing") is not in the build-log family"))
                continue
            }
            // A planted manifest must not point outside Logs/Build (`../../x`, `/etc/x`).
            guard !entry.fileName.contains("/"), entry.fileName != "..", entry.fileName != "." else {
                listing.rejected.append(reject(entry, "fileName is not a plain file name"))
                continue
            }
            let url = buildDir.appendingPathComponent(entry.fileName)
            guard fm.fileExists(atPath: url.path) else {
                listing.rejected.append(reject(entry, "log file is missing on disk"))
                continue
            }
            let modified = (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
            listing.candidates.append(LogCandidate(url: url, entry: entry, modified: modified))
        }
        listing.candidates.sort { a, b in
            let (sa, sb) = (a.entry.started ?? 0, b.entry.started ?? 0)
            if sa != sb { return sa > sb }
            let (ma, mb) = (a.modified ?? .distantPast, b.modified ?? .distantPast)
            if ma != mb { return ma > mb }
            return a.entry.fileName < b.entry.fileName
        }
        if listing.candidates.isEmpty {
            listing.emptyReason = emptyReason(manifestCount: manifest.entries.count, rejected: listing.rejected)
        }
        return listing
    }

    /// Picks a log. With `index` (0 = newest) the user's choice is taken as is. Without it, the newest candidate for
    /// which `confirm` is true wins (DESIGN §5.2: at least one executed non-planning, non-clean task; the SLF reader
    /// supplies the real check, the default accepts everything).
    public static func select(_ listing: CandidateListing, index: Int? = nil,
                              confirm: (URL) -> Bool = { _ in true }) throws -> LogCandidate {
        guard !listing.candidates.isEmpty else {
            throw LocatorError.noBuildLogs(searched: [listing.buildDir.path],
                                           reason: listing.emptyReason ?? "no candidates")
        }
        if let index {
            guard listing.candidates.indices.contains(index) else {
                throw LocatorError.indexOutOfRange(index: index, count: listing.candidates.count)
            }
            return listing.candidates[index]
        }
        if let hit = listing.candidates.first(where: { confirm($0.url) }) { return hit }
        throw LocatorError.noConfirmedLog(checked: listing.candidates.count)
    }

    private static func reject(_ entry: ManifestEntry, _ reason: String) -> RejectedEntry {
        RejectedEntry(fileName: entry.fileName, className: entry.className, domainType: entry.domainType, reason: reason)
    }

    private static func emptyReason(manifestCount: Int, rejected: [RejectedEntry]) -> String {
        if manifestCount == 0 { return "the manifest lists no logs" }
        var byReason: [String: Int] = [:]
        for item in rejected { byReason[item.reason, default: 0] += 1 }
        let summary = byReason.sorted { $0.key < $1.key }.map { "\($0.value) x \($0.key)" }.joined(separator: "; ")
        return "\(manifestCount) manifest entries, none is a usable build log (\(summary))"
    }
}
