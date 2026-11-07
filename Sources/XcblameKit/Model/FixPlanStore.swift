import Foundation

/// Stored fix plans: `<xcblame-dir>/plans/<id>.json` (docs/SCHEMA-v0.6.md "Storage"). Shared by `fix` (lane A) and
/// `verify` (lane B, which writes verdicts back with `save`). Frozen in phase 1.
public enum FixPlanStore {
    public enum StoreError: Error, Sendable, CustomStringConvertible, Equatable {
        case notFound(String)
        case ambiguous(String, [String])
        case unreadable(String)

        public var description: String {
            switch self {
            case let .notFound(id): return "no fix plan \(id) (plans are in <xcblame-dir>/plans; xcblame fix makes one)"
            case let .ambiguous(id, ids): return "\(id) matches several plans: \(ids.joined(separator: ", "))"
            case let .unreadable(why): return "fix plan unreadable: \(why)"
            }
        }
    }

    public static func directory(xcblameDir: URL) -> URL { xcblameDir.appendingPathComponent("plans") }

    public static func url(id: String, xcblameDir: URL) -> URL {
        directory(xcblameDir: xcblameDir).appendingPathComponent(id + ".json")
    }

    /// Writes (or replaces) the plan atomically; also writes `<xcblame-dir>/.gitignore`.
    @discardableResult
    public static func save(_ plan: FixPlanDocument, xcblameDir: URL) throws -> URL {
        let url = url(id: plan.id, xcblameDir: xcblameDir)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        ensureStateIgnore(in: xcblameDir)
        try (JSONReporter.encoder().encode(plan) + Data("\n".utf8)).write(to: url, options: .atomic)
        return url
    }

    /// `id` is a plan id or a unique prefix of one.
    public static func load(id: String, xcblameDir: URL) throws -> FixPlanDocument {
        let ids = list(xcblameDir: xcblameDir).map(\.id)
        let matches = ids.contains(id) ? [id] : ids.filter { $0.hasPrefix(id) }
        guard let match = matches.first else { throw StoreError.notFound(id) }
        guard matches.count == 1 else { throw StoreError.ambiguous(id, matches) }
        let url = url(id: match, xcblameDir: xcblameDir)
        do {
            return try JSONReporter.decoder().decode(FixPlanDocument.self, from: Data(contentsOf: url))
        } catch {
            throw StoreError.unreadable("\(url.lastPathComponent): \(error)")
        }
    }

    /// Readable plans, newest `generatedAt` first (ties by id); unreadable files are skipped.
    public static func list(xcblameDir: URL) -> [FixPlanDocument] {
        let dir = directory(xcblameDir: xcblameDir)
        let urls = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension == "json" && !$0.lastPathComponent.hasPrefix(".") }
            .compactMap { try? JSONReporter.decoder().decode(FixPlanDocument.self, from: Data(contentsOf: $0)) }
            .sorted { $0.generatedAt != $1.generatedAt ? $0.generatedAt > $1.generatedAt : $0.id < $1.id }
    }
}
