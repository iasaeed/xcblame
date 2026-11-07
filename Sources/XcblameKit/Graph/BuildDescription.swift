import Foundation

/// The build service's build description for one build (DESIGN §5.11): `manifest.json` commands, `target-graph.txt`
/// and `build-request.json` from `<DerivedData>/Build/Intermediates.noindex/XCBuildData/<signature>.xcbuilddata/` or a
/// `.xcblame/snapshots/<log-uuid>/` copy.
public struct BuildDescription: Sendable {
    /// One llbuild manifest command.
    public struct Command: Sendable {
        public var key: String
        public var tool: String
        public var inputs: [String]
        public var outputs: [String]
    }

    /// One explicit dependency of `target-graph.txt`: `from` depends on `to`.
    public struct Edge: Sendable, Equatable {
        public var from: String
        public var to: String
    }

    public struct BuildRequest: Sendable {
        public var action: String?
        public var enableIndexBuildArena: Bool?
        /// Every other top-level scalar of `build-request.json`, as text.
        public var raw: [String: String]
    }

    public var signature: String?
    public var directory: URL
    public var commands: [Command]
    public var targetGraph: [Edge]
    public var buildRequest: BuildRequest
    /// Where the locator found it: `snapshot` (a `.xcblame/snapshots/<log-uuid>/` copy or an explicit
    /// `--build-description` folder) or `live` (DerivedData `XCBuildData`). `load` sets `snapshot`.
    public var basis: String = "snapshot"
    /// How it was matched to the log (signature, key coverage), for `graph.notes`.
    public var notes: [String] = []

    /// Reads `manifest.json` (or `manifest.json.gz`), and when present `target-graph.txt`, `build-request.json` and a
    /// `SIGNATURE` file. The signature comes from `SIGNATURE`, else from a `<hex>.xcbuilddata` folder name.
    public static func load(directory: URL) throws -> BuildDescription {
        let fm = FileManager.default
        let plain = directory.appendingPathComponent("manifest.json")
        let gzipped = directory.appendingPathComponent("manifest.json.gz")
        let manifestData: Data
        if fm.fileExists(atPath: plain.path) {
            manifestData = try Data(contentsOf: plain)
        } else if fm.fileExists(atPath: gzipped.path) {
            let inflated = try GzipFile.inflate(contentsOf: gzipped)
            if inflated.truncated || inflated.capReached {
                throw XcblameError.readerFailure("\(gzipped.path): manifest is truncated")
            }
            manifestData = Data(inflated.bytes)
        } else {
            throw XcblameError.readerFailure("\(directory.path) has no manifest.json or manifest.json.gz")
        }
        let commands = try parseManifest(manifestData, path: directory.path)

        let graphURL = directory.appendingPathComponent("target-graph.txt")
        let targetGraph = (try? String(contentsOf: graphURL, encoding: .utf8)).map(parseTargetGraph) ?? []
        let requestURL = directory.appendingPathComponent("build-request.json")
        let request = (try? Data(contentsOf: requestURL)).flatMap(parseBuildRequest)
            ?? BuildRequest(action: nil, enableIndexBuildArena: nil, raw: [:])
        return BuildDescription(signature: signature(of: directory), directory: directory, commands: commands,
                                targetGraph: targetGraph, buildRequest: request)
    }

    /// `SIGNATURE` file content or the `<hex>.xcbuilddata` folder name, without the extension; nil otherwise.
    static func signature(of directory: URL) -> String? {
        let file = directory.appendingPathComponent("SIGNATURE")
        if let text = try? String(contentsOf: file, encoding: .utf8) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let stem = trimmed.hasSuffix(".xcbuilddata") ? String(trimmed.dropLast(".xcbuilddata".count)) : trimmed
            if isHexSignature(stem) { return stem }
        }
        if directory.pathExtension == "xcbuilddata" {
            let stem = directory.deletingPathExtension().lastPathComponent
            if isHexSignature(stem) { return stem }
        }
        return nil
    }

    static func isHexSignature(_ text: String) -> Bool {
        text.count == 32 && text.allSatisfy { $0.isHexDigit }
    }

    // ponytail: JSONSerialization loads the whole manifest (1.6 MB on a 13-target app); stream it when manifests pass ~50 MB.
    static func parseManifest(_ data: Data, path: String) throws -> [Command] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let commands = root["commands"] as? [String: Any] else {
            throw XcblameError.readerFailure("\(path): manifest has no commands object")
        }
        // Sorted keys: command order is deterministic across runs.
        return commands.keys.sorted().compactMap { key in
            guard let body = commands[key] as? [String: Any] else { return nil }
            return Command(key: key, tool: body["tool"] as? String ?? "",
                           inputs: body["inputs"] as? [String] ?? [], outputs: body["outputs"] as? [String] ?? [])
        }
    }

    /// `Target 'X' in project 'P'` opens a block; each `... dependency on target 'Y' ...` line inside it is an edge
    /// X → Y. Duplicates (one block per platform variant) are kept once.
    static func parseTargetGraph(_ text: String) -> [Edge] {
        var edges: [Edge] = []
        var seen = Set<String>()
        var current: String?
        for line in text.split(whereSeparator: \.isNewline) {
            if line.hasPrefix("Target '") {
                current = quoted(after: "Target '", in: line)
            } else if let from = current, let to = quoted(after: "dependency on target '", in: line) {
                if seen.insert(from + "\u{1F}" + to).inserted { edges.append(Edge(from: from, to: to)) }
            }
        }
        return edges
    }

    private static func quoted(after marker: String, in line: Substring) -> String? {
        guard let open = line.range(of: marker) else { return nil }
        let rest = line[open.upperBound...]
        guard let close = rest.firstIndex(of: "'") else { return nil }
        return String(rest[..<close])
    }

    /// `parameters.action`, `enableIndexBuildArena`, and every scalar leaf flattened with dotted keys (arrays skipped).
    static func parseBuildRequest(_ data: Data) -> BuildRequest? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        var raw: [String: String] = [:]
        func flatten(_ object: [String: Any], prefix: String) {
            for (key, value) in object {
                let name = prefix.isEmpty ? key : prefix + "." + key
                if let dict = value as? [String: Any] {
                    flatten(dict, prefix: name)
                } else if let number = value as? NSNumber {
                    raw[name] = CFGetTypeID(number) == CFBooleanGetTypeID() ? (number.boolValue ? "true" : "false")
                        : number.stringValue
                } else if let string = value as? String {
                    raw[name] = string
                }
            }
        }
        flatten(root, prefix: "")
        let parameters = root["parameters"] as? [String: Any]
        return BuildRequest(action: parameters?["action"] as? String,
                            enableIndexBuildArena: (root["enableIndexBuildArena"] as? NSNumber)?.boolValue,
                            raw: raw)
    }
}
