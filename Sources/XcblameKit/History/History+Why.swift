import Foundation

// v0.5 lane B (docs/SCHEMA-v0.5.md "History task index"): the previous index for cause attribution and the `why`
// capture in saved rows.
extension History {
    /// Decodes any value: an entry's `deep` member is only checked for presence (`build --deep` wrote it).
    struct DeepMarker: Decodable {
        init(from decoder: Decoder) throws {}
    }

    /// What `previousIndex` reads of an entry: the build key, the log identity, the rows and whether it is a deep build.
    private struct KeyedEntry: Decodable {
        struct Build: Decodable {
            var kind: String?
            var scheme: String?
            var configuration: String?
            var destination: String?
            var span: Double?
        }
        struct Input: Decodable {
            var path: String?
            var layout: String?
        }
        var build: Build?
        var input: Input?
        var logId: String?
        var taskIndexRows: [TaskIndexRow]?
        var deep: DeepMarker?
    }

    /// The newest entry other than `document`'s own log with the same build key (`kind` aside: scheme,
    /// configuration, destination), with its task rows. Doctor documents, clean-action logs and entries without rows
    /// are skipped; a `build --deep` document looks only at `build --deep` entries, any other document skips them. Nil when there is none (or `directory` does not exist).
    public static func previousIndex(for document: ReportDocument, directory: URL) throws -> PreviousIndex? {
        previousLookup(for: document, directory: directory, logEnd: nil).index
    }

    /// `previousIndex` plus the `incremental.notes` lines about the choice: a `build --deep` entry skipped as the
    /// would-be previous build (instrumented flags in its own DerivedData: every Swift command line differs), a key
    /// matched with configuration or destination unknown on one side (the build description gives them; a log
    /// analyzed without one has neither), and a previous entry recorded after `logEnd` (the analyzed log ended).
    ///
    /// The key: the scheme is equal; the configuration is equal or unknown on one side; the destinations agree
    /// (`BuildContext.destinationsAgree`: an unknown side or architecture agrees). So `analyze --build-description`
    /// and `analyze` / `why --log` of the same build find each other in either order.
    static func previousLookup(for document: ReportDocument, directory: URL,
                               logEnd: Date?) -> (index: PreviousIndex?, notes: [String]) {
        let own = document.input.path.flatMap(logIdentity(path:))
        let ownName = document.input.path.map { (($0 as NSString).lastPathComponent as NSString).deletingPathExtension }
        var skippedDeep: [String] = []
        var notes: [String] = []
        let wantDeep = document.deep != nil
        let skippedWhat = wantDeep ? "is an ordinary build (no timing flags) while this is a build --deep"
            : "is a build --deep (timing flags in its own DerivedData)"
        for item in list(directory: directory, details: false) {
            guard let inflated = try? GzipFile.inflate(contentsOf: item.url),
                  let entry = try? JSONDecoder().decode(KeyedEntry.self, from: Data(inflated.bytes)) else { continue }
            if let own, entry.logId == own { continue }
            if entry.logId == nil, let ownName, let path = entry.input?.path,
               ((path as NSString).lastPathComponent as NSString).deletingPathExtension == ownName,
               UUID(uuidString: ownName) != nil { continue }
            guard entry.input?.layout != "project", entry.build?.kind != "clean-action",
                  let rows = entry.taskIndexRows, !rows.isEmpty,
                  entry.build?.scheme == document.build.scheme,
                  entry.build?.configuration == nil || document.build.configuration == nil
                    || entry.build?.configuration == document.build.configuration,
                  BuildContext.destinationsAgree(entry.build?.destination, document.build.destination) else { continue }
            // A build --deep compares with the previous build --deep, an ordinary build with an ordinary one: the
            // timing flags change every Swift command line, so across the two every compile would be settingsChanged.
            if (entry.deep != nil) != wantDeep {
                skippedDeep.append(item.id)
                continue
            }
            if let first = skippedDeep.first {
                notes.append("basis: build \(first)" + (skippedDeep.count > 1 ? " (and \(skippedDeep.count - 1) more)" : "")
                    + " of the same key " + skippedWhat + " and was skipped; compared with build \(item.id)")
            }
            let unknown = [("configuration", entry.build?.configuration, document.build.configuration),
                           ("destination", entry.build?.destination, document.build.destination)]
                .filter { ($0.1 == nil) != ($0.2 == nil) }.map(\.0)
            if !unknown.isEmpty {
                notes.append("basis: build \(item.id) matched on the scheme with the \(unknown.joined(separator: " and ")) "
                    + "known on one side only (a build description supplies them)")
            }
            if let logEnd, let time = item.time, time > logEnd.addingTimeInterval(1) {
                notes.append("limit: build \(item.id) was recorded after this log ended; history compares with the newest "
                    + "other entry of the same key, which may be a later build")
            }
            return (PreviousIndex(id: item.id, time: item.time, kind: entry.build?.kind ?? item.kind, rows: rows,
                                  span: entry.build?.span), notes)
        }
        if let first = skippedDeep.first {
            notes.append("basis: build \(first)" + (skippedDeep.count > 1 ? " (and \(skippedDeep.count - 1) more)" : "")
                + " of the same key " + skippedWhat + " and was skipped; no other previous build is recorded")
        } else if wantDeep {
            notes.append("basis: no previous build --deep of this key is recorded (a build --deep is compared only with "
                + "another build --deep)")
        }
        return (nil, notes)
    }

    /// `save(document:model:directory:)` with the `why` capture merged into the rows (`outputHash`, `outputBytes`,
    /// `inputHashes`): the entry is written as usual, then rewritten with the extended rows when the capture covers
    /// any of them. Rows the capture does not cover stay 7 elements long.
    public static func save(document: ReportDocument, model: BuildModel, directory: URL,
                            capture: OutputHashes.Capture) throws -> URL {
        let url = try save(document: document, model: model, directory: directory)
        var covered = false
        let rows = taskIndexRows(document, model).map { row -> TaskIndexRow in
            guard let key = row.key else { return row }
            var row = row
            if let output = capture.outputs[key] {
                row.outputHash = output.hash
                row.outputBytes = output.bytes
                covered = true
            }
            if let inputs = capture.inputs[key], !inputs.isEmpty {
                row.inputHashes = inputs
                covered = true
            }
            return row
        }
        guard covered else { return url }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let json = try encoder.encode(CapturedEntry(document: trimmed(document), rows: rows, logId: logIdentity(of: url)))
        let staging = directory.appendingPathComponent(".\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: staging) }
        try json.write(to: staging)
        try gzip(staging, to: url)
        return url
    }

    /// The entry layout of `History.save`: the report's members at top level plus `taskIndexRows` and `logId`.
    private struct CapturedEntry: Encodable {
        var document: ReportDocument
        var rows: [TaskIndexRow]
        var logId: String?

        private enum Key: String, CodingKey { case taskIndexRows, logId }

        func encode(to encoder: Encoder) throws {
            try document.encode(to: encoder)
            var container = encoder.container(keyedBy: Key.self)
            try container.encode(rows, forKey: .taskIndexRows)
            try container.encodeIfPresent(logId, forKey: .logId)
        }
    }
}
