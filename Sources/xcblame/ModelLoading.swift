import Foundation
import XcblameKit

/// What a reader may need besides the path.
struct LoadOptions: Sendable {
    var verbose: Bool = false
    var quiet: Bool = false
    /// `--index`: pick this Locator candidate (0 = newest) instead of the newest one confirmed by content.
    var index: Int?
}

/// A decoded model plus where it really came from (the selected log when the input was a folder).
struct LoadedModel {
    var model: BuildModel
    /// The file or bundle that was read.
    var path: String
    /// One-line explanation of a selection the user did not make themselves (Locator picks), for stderr.
    var note: String?
    /// `schemeIdentifier-schemeName` of the log's `LogStoreManifest.plist` entry; nil when there is no manifest or
    /// the entry names none (v0.4: `build.scheme`).
    var scheme: String?
}

/// What `analyze <path>` read: a build to analyze, or a saved xcblame JSON report to re-render (DESIGN §3.2).
enum LoadedInput {
    case model(LoadedModel)
    case report(ReportDocument, path: String)
}

/// A plain `.json` file whose top-level `schemaVersion` starts with `xcblame.report/` is a saved report; anything else
/// goes to `loadModel`.
func loadModelOrReport(at url: URL, options: LoadOptions) throws -> LoadedInput {
    if isSavedReport(url) { return .report(try loadSavedReport(at: url), path: url.path) }
    return .model(try loadModel(at: url, options: options))
}

private func isSavedReport(_ url: URL) -> Bool {
    struct Probe: Decodable { var schemaVersion: String? }
    guard url.pathExtension == "json", let data = try? Data(contentsOf: url, options: .mappedIfSafe),
          let version = (try? JSONDecoder().decode(Probe.self, from: data))?.schemaVersion else { return false }
    return version.hasPrefix("xcblame.report/")
}

/// The single injection point for readers. `url` may be an `.xcactivitylog`, an `.xcresult` bundle, an xcresult build
/// log JSON (`.json` / `.json.gz`, as written by `xcresulttool get log --type build`), a DerivedData folder, a
/// `Logs/Build` folder or a project folder (DESIGN §5.1, §5.2).
func loadModel(at url: URL, options: LoadOptions) throws -> LoadedModel {
    var isDirectory: ObjCBool = false
    FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
    if isDirectory.boolValue {
        if url.pathExtension == "xcresult" {
            return LoadedModel(model: try readXCResult { try XCResultReader.read(resultBundle: url) }, path: url.path)
        }
        return try loadFromBuildLogFolder(url, options: options)
    }
    return LoadedModel(model: try loadFile(url), path: url.path, scheme: manifestScheme(ofLog: url))
}

// MARK: - Single files

/// The manifest next to an `.xcactivitylog` (`Logs/Build/LogStoreManifest.plist`) names the scheme that wrote it.
private func manifestScheme(ofLog url: URL) -> String? {
    guard url.pathExtension == "xcactivitylog",
          let manifest = try? ManifestReader.read(url: url.deletingLastPathComponent().appendingPathComponent(ManifestReader.fileName))
    else { return nil }
    return manifest.entries.first { $0.fileName == url.lastPathComponent }?.schemeName
}

private func loadFile(_ url: URL) throws -> BuildModel {
    let data: Data
    do { data = try Data(contentsOf: url, options: .mappedIfSafe) } catch { throw XcblameError.logNotFound(url.path) }
    if url.pathExtension == "xcactivitylog" { return try readSLF(data, path: url.path) }

    // Anything else is sniffed: an SLF log (gzip or inflated) or the xcresult build-log JSON (gzip or plain).
    if data.starts(with: SLFTokenizer.header) { return try readSLF(data, path: url.path) }
    var json = data
    if GzipFile.isGzip(data) {
        let inflated: InflateResult
        do { inflated = try GzipFile.inflate(data) } catch {
            throw XcblameError.readerFailure("\(url.path): \(error)")
        }
        if inflated.bytes.starts(with: SLFTokenizer.header) { return try readSLF(data, path: url.path) }
        json = Data(inflated.bytes)
    }
    guard json.first(where: { !$0.isASCIIWhitespace }) == UInt8(ascii: "{") else {
        throw XcblameError.readerFailure(
            "\(url.path) is neither an .xcactivitylog nor an xcresult build-log JSON (.json or .json.gz)")
    }
    return try readXCResult { try XCResultReader.read(jsonData: json) }
}

private func readSLF(_ data: Data, path: String) throws -> BuildModel {
    let raw: RawLog
    do { raw = try SLFReader.read(data: data) } catch {
        throw XcblameError.readerFailure("\(path): \(error)")
    }
    return BuildModelBuilder.build(raw, reader: .slf)
}

private func readXCResult(_ read: () throws -> RawLog) throws -> BuildModel {
    do { return BuildModelBuilder.build(try read(), reader: .xcresult) } catch {
        throw XcblameError.readerFailure((error as? LocalizedError)?.errorDescription ?? "\(error)")
    }
}

// MARK: - DerivedData / Logs/Build folders

/// Kinds that do not count as "a build happened": a log holding only these is a clean action or a planning stub.
private let nonBuildKinds = BuildModelBuilder.nonBuildKinds

private func loadFromBuildLogFolder(_ url: URL, options: LoadOptions) throws -> LoadedModel {
    let listing = try candidateListing(for: url)
    // `confirm` decodes a candidate fully (the early stop of DESIGN §5.2 is not implemented in v0.1: the cost is one
    // full decode per rejected candidate, which are small clean/planning logs). The confirmed model is kept so the
    // selected log is never decoded twice.
    var confirmed: [URL: BuildModel] = [:]
    let selected: LogCandidate
    do {
        selected = try Locator.select(listing, index: options.index) { logURL in
            guard let model = try? loadFile(logURL), model.tasks.contains(where: { !nonBuildKinds.contains($0.kind) })
            else { return false }
            confirmed[logURL] = model
            return true
        }
    } catch {
        throw XcblameError.noBuildLog(describe(error, listing: listing))
    }
    let model = try confirmed[selected.url] ?? loadFile(selected.url)
    let position = listing.candidates.firstIndex(of: selected).map { "candidate \($0) of \(listing.candidates.count)" } ?? ""
    let how = options.index == nil ? "newest build log with an executed build task" : "chosen with --index"
    return LoadedModel(model: model, path: selected.url.path,
                       note: "selected \(selected.url.lastPathComponent) (\(position), \(how))",
                       scheme: selected.entry.schemeName)
}

/// Resolves a folder: a DerivedData or `Logs/Build` folder is taken as is; a project folder (holding an
/// `.xcworkspace` / `.xcodeproj`) is matched to its DerivedData by `info.plist` `WorkspacePath` (workspace settings,
/// custom location, default root). Nothing else: an unrelated project's logs are never picked.
private func candidateListing(for url: URL) throws -> CandidateListing {
    let resolution = DerivedDataLocator(explicitPath: url, customLocation: { nil }).locate()
    if let buildDir = resolution.buildDir, resolution.source == "explicit" { return Locator.candidates(in: buildDir) }
    var lines = resolution.searched.filter { $0.source == "explicit" }.map { "  \($0.path): \($0.outcome)" }
    if let project = DerivedDataLocator.locateProject(in: url) {
        if let buildDir = project.buildDir { return Locator.candidates(in: buildDir) }
        lines = project.searched.map { "  [\($0.source)] \($0.path): \($0.outcome)" }
        throw XcblameError.noBuildLog((["no build log found: no DerivedData matches the project in \(url.path); "
            + "searched:"] + lines + [Locator.noLogHint]).joined(separator: "\n"))
    }
    throw XcblameError.noBuildLog(
        (["no build log found: \(url.path) is not a DerivedData folder, a Logs/Build folder with a "
            + ManifestReader.fileName + " or a project folder"] + lines + [Locator.noLogHint]).joined(separator: "\n"))
}

/// `--list`: the candidates the Locator would choose between, newest first, with the manifest facts (never titles
/// for selection; the title column is display only).
func listCandidates(at url: URL) throws -> String {
    var isDirectory: ObjCBool = false
    FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
    guard isDirectory.boolValue, url.pathExtension != "xcresult" else {
        throw XcblameError.usage("--list needs a DerivedData, Logs/Build or project folder, not \(url.path)")
    }
    let listing = try candidateListing(for: url)
    guard !listing.candidates.isEmpty else {
        throw XcblameError.noBuildLog(describe(
            LocatorError.noBuildLogs(searched: [listing.buildDir.path], reason: listing.emptyReason ?? "no candidates"),
            listing: listing))
    }
    let formatter = ISO8601DateFormatter()
    var lines = ["\(listing.candidates.count) build log candidate(s) in \(listing.buildDir.path), newest first:"]
    for (index, candidate) in listing.candidates.enumerated() {
        let entry = candidate.entry
        let started = entry.started.map { formatter.string(from: Date(timeIntervalSince1970: $0)) } ?? "unknown time"
        let status = entry.status.map { ["S": "success", "W": "warnings", "E": "errors"][$0] ?? $0 } ?? "unknown status"
        lines.append("  [\(index)] \(candidate.url.lastPathComponent)  \(started)  \(entry.schemeName ?? "-")  "
            + "\(status)  \(entry.title ?? "")")
    }
    lines.append("pass --index <n> to analyze one; without it the newest one with an executed build task is used")
    return lines.joined(separator: "\n")
}

/// Error text for a failed selection: the locator's message (with the no-log hint) plus every manifest entry seen.
private func describe(_ error: Error, listing: CandidateListing) -> String {
    var lines = [(error as? LocalizedError)?.errorDescription ?? "\(error)"]
    if !listing.candidates.isEmpty {
        lines.append("candidates:")
        for (index, candidate) in listing.candidates.enumerated() {
            lines.append("  [\(index)] \(candidate.url.lastPathComponent)  \(candidate.entry.title ?? "")")
        }
    }
    if !listing.rejected.isEmpty {
        lines.append("not candidates:")
        for item in listing.rejected { lines.append("  \(item.fileName): \(item.reason)") }
    }
    if !lines[0].contains(Locator.noLogHint) { lines.append(Locator.noLogHint) }
    return lines.joined(separator: "\n")
}

/// Reads a JSON dump of a `BuildModel` (`analyze --model-json`).
func loadModelJSON(at url: URL) throws -> BuildModel {
    let data: Data
    do { data = try Data(contentsOf: url) } catch { throw XcblameError.logNotFound(url.path) }
    do { return try JSONDecoder().decode(BuildModel.self, from: data) } catch {
        throw XcblameError.readerFailure("\(url.path) is not a BuildModel JSON dump (\(error))")
    }
}

private extension UInt8 {
    var isASCIIWhitespace: Bool { self == 0x20 || self == 0x0A || self == 0x0D || self == 0x09 }
}
