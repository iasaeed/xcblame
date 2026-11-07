import Foundation

/// Finds the project container `doctor` and `analyze` read (docs/SCHEMA-v0.3.md).
public enum ProjectLocator {
    /// The container in `dir` (or `dir` itself when it is one): `.xcworkspace` before `.xcodeproj` before
    /// `Package.swift`, each group sorted by name. A workspace inside an `.xcodeproj` (`project.xcworkspace`) never
    /// counts: it is that project's own. Nil when `dir` holds none.
    public static func find(startingAt dir: URL) -> URL? {
        let url = dir.standardizedFileURL
        if ["xcworkspace", "xcodeproj"].contains(url.pathExtension) || url.lastPathComponent == "Package.swift" {
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
        if let container = DerivedDataLocator.projectContainers(in: url).first { return container }
        let manifest = url.appendingPathComponent("Package.swift")
        return FileManager.default.fileExists(atPath: manifest.path) ? manifest : nil
    }

    /// The workspace or project that produced a build log: `WorkspacePath` in the `info.plist` of the log's
    /// DerivedData (`derivedData`, else the folder three levels above `<dd>/Logs/Build/<uuid>.xcactivitylog`). Nil
    /// when there is no such plist or the path it names no longer exists (a log copied from another machine).
    public static func find(forBuildLog log: URL, derivedData: URL?) -> URL? {
        let dd = derivedData ?? log.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard let info = NSDictionary(contentsOf: dd.appendingPathComponent("info.plist")),
              let path = info["WorkspacePath"] as? String, !path.isEmpty else { return nil }
        return FileManager.default.fileExists(atPath: path) ? URL(fileURLWithPath: path).standardizedFileURL : nil
    }
}
