import CryptoKit
import Foundation

// v0.5 lane B (docs/SCHEMA-v0.5.md "History task index"): what `why` hashes after a build so the next comparison can
// tell an interface change (precedence 4) and timestamp churn (precedence 5) apart.
public enum OutputHashes {
    public struct Output: Sendable, Equatable, Codable {
        /// First 16 hex digits of SHA256 of the file.
        public var hash: String
        public var bytes: Int

        public init(hash: String, bytes: Int) {
            self.hash = hash
            self.bytes = bytes
        }
    }

    public struct Capture: Sendable, Equatable {
        /// Task key → its emitted `.swiftmodule` (or `.abi.json` when present) of an executed emit-module task.
        public var outputs: [String: Output]
        /// Task key → portable input path (`History.portable`) → first 16 hex of SHA256, for executed tasks only.
        public var inputs: [String: [String: String]]
        /// Task key → portable input path → modification time (Unix seconds) when hashed; not stored in history,
        /// read by the timestamp-churn evidence of this build only.
        public var inputMtimes: [String: [String: Double]]

        public init(outputs: [String: Output], inputs: [String: [String: String]],
                    inputMtimes: [String: [String: Double]] = [:]) {
            self.outputs = outputs
            self.inputs = inputs
            self.inputMtimes = inputMtimes
        }
    }

    /// Input files hashed per capture at most (the largest projects have tens of thousands of sources; the cap keeps a
    /// `why` run's hashing well under a second of I/O per thousand files).
    public static let inputCap = 5_000
    /// Files above this size are not hashed (generated blobs, assets).
    public static let maxFileBytes = 32 << 20

    /// Hashes the outputs and inputs of the executed tasks of `model`: the emitted module of each keyed emit-module
    /// task (`-emit-module-path`, its `.abi.json` sibling when present, else a `<Target>.swiftmodule` found under
    /// `derivedData`), and the source files of each keyed compile task (capped at `inputCap`). Files that cannot be read
    /// are skipped; the capture never throws for a missing file.
    public static func capture(model: BuildModel, derivedData: URL) throws -> Capture {
        let roots = History.projectRoots(of: model)
        var outputs: [String: Output] = [:]
        var inputs: [String: [String: String]] = [:]
        var mtimes: [String: [String: Double]] = [:]
        var hashed = 0
        for item in Timing.timeline(model).counted {
            let task = item.task
            guard let key = task.taskKey else { continue }
            if task.kind == .swiftEmitModule, let module = emittedModule(task, model: model, derivedData: derivedData),
               let output = hash(module) {
                outputs[key] = output
            }
            guard [.swiftCompile, .clangCompile].contains(task.kind), hashed < inputCap else { continue }
            var files: [String: String] = [:]
            var modified: [String: Double] = [:]
            for path in FileAttribution.files(of: task) where isSource(path) && hashed < inputCap {
                guard let output = hash(URL(fileURLWithPath: path)) else { continue }
                let portable = History.portable(path, roots: roots)
                files[portable] = output.hash
                if let date = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date {
                    modified[portable] = date.timeIntervalSince1970
                }
                hashed += 1
            }
            if !files.isEmpty { inputs[key] = files }
            if !modified.isEmpty { mtimes[key] = modified }
        }
        return Capture(outputs: outputs, inputs: inputs, inputMtimes: mtimes)
    }

    /// The `.abi.json` next to the emitted `.swiftmodule` when it exists (it changes only with the interface), else
    /// the `.swiftmodule` itself.
    static func emittedModule(_ task: BuildTask, model: BuildModel, derivedData: URL) -> URL? {
        let fm = FileManager.default
        var module: URL?
        if let details = task.commandDetails, let path = argument(after: "-emit-module-path", in: details) {
            module = URL(fileURLWithPath: path)
        } else if let target = task.targetId.flatMap({ model.targets.indices.contains($0) ? model.targets[$0].name : nil }) {
            module = find("\(target).swiftmodule", under: derivedData.appendingPathComponent("Build/Intermediates.noindex"))
        }
        guard let module else { return nil }
        let abi = module.deletingPathExtension().appendingPathExtension("abi.json")
        if fm.fileExists(atPath: abi.path) { return abi }
        return fm.fileExists(atPath: module.path) ? module : nil
    }

    /// First 16 hex of SHA256 and the size; nil for a missing, unreadable, too large or non-regular file.
    static func hash(_ url: URL) -> Output? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = (attributes[.size] as? NSNumber)?.intValue, size <= maxFileBytes,
              let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        let hex = SHA256.hash(data: data).prefix(8).map { String(format: "%02x", $0) }.joined()
        return Output(hash: hex, bytes: size)
    }

    static func isSource(_ path: String) -> Bool {
        ["swift", "c", "m", "mm", "cpp", "cc", "cxx"].contains((path as NSString).pathExtension.lowercased())
    }

    /// The word after `flag` in a command line (backslash-escaped spaces kept); nil when absent.
    static func argument(after flag: String, in details: String) -> String? {
        guard let range = details.range(of: flag + " ") else { return nil }
        var value = ""
        var escaped = false
        for character in details[range.upperBound...] {
            if escaped { value.append(character); escaped = false; continue }
            if character == "\\" { escaped = true; continue }
            if character == " " || character == "\n" || character == "\r" { break }
            value.append(character)
        }
        return value.isEmpty ? nil : value
    }

    /// Breadth-first search for a file or bundle named `name`, at most 6 levels deep.
    static func find(_ name: String, under root: URL) -> URL? {
        var level = [root]
        for _ in 0..<6 {
            var next: [URL] = []
            for folder in level {
                let children = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
                for child in children {
                    if child.lastPathComponent == name { return child }
                    if (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true { next.append(child) }
                }
            }
            if next.isEmpty { return nil }
            level = next
        }
        return nil
    }
}
