import Foundation

/// One directory the locator looked at, for the "searched" list in error output ([TM] XLP#214, BTA#30).
public struct SearchedDirectory: Sendable, Equatable {
    public var path: String
    /// Which rule produced it: `explicit`, `derivedDataPath`, `workspace-settings`, `defaults`, `default`.
    public var source: String
    public var outcome: String
}

public struct DerivedDataResolution: Sendable, Equatable {
    /// The `Logs/Build` directory; nil when nothing matched.
    public var buildDir: URL?
    public var derivedData: URL?
    public var source: String?
    /// Every directory looked at, in search order.
    public var searched: [SearchedDirectory]

    /// Multi-line text for the failure case; lists every directory searched.
    public var failureDescription: String {
        var lines = ["no DerivedData with build logs found; searched:"]
        if searched.isEmpty { lines.append("  (nothing: no path, workspace or defaults to look at)") }
        for item in searched { lines.append("  [\(item.source)] \(item.path): \(item.outcome)") }
        return lines.joined(separator: "\n")
    }
}

/// Finds the DerivedData of a project (DESIGN §5.2). Search order: explicit path, `-derivedDataPath`, the workspace's
/// `WorkspaceSettings.xcsettings`, `IDECustomDerivedDataLocation`, then `~/Library/Developer/Xcode/DerivedData`.
/// A directory is accepted when it is itself a `Logs/Build` dir, a DerivedData dir (`Logs/Build` inside), or a
/// DerivedData root whose child `info.plist` `WorkspacePath` equals `workspace` (never a recomputed hash).
public struct DerivedDataLocator: Sendable {
    public var explicitPath: URL?
    public var derivedDataPathArgument: URL?
    /// The `.xcworkspace` or `.xcodeproj` being built.
    public var workspace: URL?
    public var home: URL
    /// `defaults read com.apple.dt.Xcode IDECustomDerivedDataLocation`; injectable for tests.
    public var customLocation: @Sendable () -> String?

    public init(explicitPath: URL? = nil, derivedDataPathArgument: URL? = nil, workspace: URL? = nil,
                home: URL = FileManager.default.homeDirectoryForCurrentUser,
                customLocation: @escaping @Sendable () -> String? = DerivedDataLocator.readCustomLocation) {
        self.explicitPath = explicitPath
        self.derivedDataPathArgument = derivedDataPathArgument
        self.workspace = workspace
        self.home = home
        self.customLocation = customLocation
    }

    /// 2 s timeout; nil when the key is unset (the usual case).
    @Sendable public static func readCustomLocation() -> String? {
        runProbe(["defaults", "read", "com.apple.dt.Xcode", "IDECustomDerivedDataLocation"], timeout: 2)
    }

    public func locate() -> DerivedDataResolution {
        var searched: [SearchedDirectory] = []
        var roots: [(URL, String)] = []
        if let explicitPath { roots.append((explicitPath, "explicit")) }
        if let derivedDataPathArgument { roots.append((derivedDataPathArgument, "derivedDataPath")) }
        if let workspace {
            for dir in workspaceSettingsLocations(workspace) { roots.append((dir, "workspace-settings")) }
        }
        if let custom = customLocation(), !custom.isEmpty {
            roots.append((URL(fileURLWithPath: (custom as NSString).expandingTildeInPath), "defaults"))
        }
        roots.append((home.appendingPathComponent("Library/Developer/Xcode/DerivedData"), "default"))

        var seen: Set<String> = []
        for (root, source) in roots where seen.insert(root.standardizedFileURL.path).inserted {
            if let hit = resolve(root, source: source, searched: &searched) {
                return DerivedDataResolution(buildDir: hit.buildDir, derivedData: hit.derivedData, source: source,
                                             searched: searched)
            }
        }
        return DerivedDataResolution(buildDir: nil, derivedData: nil, source: nil, searched: searched)
    }

    // MARK: - Per-directory resolution

    private func resolve(_ dir: URL, source: String, searched: inout [SearchedDirectory])
        -> (buildDir: URL, derivedData: URL?)? {
        let fm = FileManager.default
        func note(_ outcome: String) { searched.append(SearchedDirectory(path: dir.path, source: source, outcome: outcome)) }
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else {
            note("does not exist")
            return nil
        }
        if fm.fileExists(atPath: dir.appendingPathComponent(ManifestReader.fileName).path) {
            note("is a Logs/Build directory")
            return (dir, nil)
        }
        let logs = dir.appendingPathComponent("Logs/Build")
        if fm.fileExists(atPath: logs.appendingPathComponent(ManifestReader.fileName).path) {
            note("DerivedData with build logs")
            return (logs, dir)
        }
        guard let workspace else {
            note("no build logs here and no workspace path given to match children against")
            return nil
        }
        let wanted = Self.normalized(workspace.path)
        let children = ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var inspected = 0
        for child in children {
            guard let info = NSDictionary(contentsOf: child.appendingPathComponent("info.plist")),
                  let path = info["WorkspacePath"] as? String else { continue }
            inspected += 1
            guard Self.normalized(path) == wanted else { continue }
            let logs = child.appendingPathComponent("Logs/Build")
            if fm.fileExists(atPath: logs.appendingPathComponent(ManifestReader.fileName).path) {
                note("matched \(child.lastPathComponent) by WorkspacePath")
                return (logs, child)
            }
            note("matched \(child.lastPathComponent) by WorkspacePath but it has no Logs/Build manifest")
            return nil
        }
        note("\(inspected) DerivedData folders inspected, none has WorkspacePath \(workspace.path)")
        return nil
    }

    static func normalized(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }

    // MARK: - WorkspaceSettings.xcsettings

    /// Custom DerivedData directories named by the workspace's `WorkspaceSettings.xcsettings`
    /// (`DerivedDataLocationStyle` `AbsolutePath` / `WorkspaceRelativePath` + `DerivedDataCustomLocation`).
    func workspaceSettingsLocations(_ workspace: URL) -> [URL] {
        var containers = [workspace]
        if workspace.pathExtension == "xcodeproj" { containers.append(workspace.appendingPathComponent("project.xcworkspace")) }
        let base = workspace.deletingLastPathComponent()
        var result: [URL] = []
        for container in containers {
            var files = [container.appendingPathComponent("xcshareddata/WorkspaceSettings.xcsettings")]
            let userData = container.appendingPathComponent("xcuserdata")
            for user in (try? FileManager.default.contentsOfDirectory(at: userData, includingPropertiesForKeys: nil)) ?? [] {
                files.append(user.appendingPathComponent("WorkspaceSettings.xcsettings"))
            }
            for file in files {
                guard let dict = NSDictionary(contentsOf: file),
                      let style = dict["DerivedDataLocationStyle"] as? String,
                      let custom = dict["DerivedDataCustomLocation"] as? String, !custom.isEmpty else { continue }
                switch style {
                case "AbsolutePath": result.append(URL(fileURLWithPath: custom))
                case "WorkspaceRelativePath": result.append(URL(fileURLWithPath: custom, relativeTo: base).standardizedFileURL)
                default: break
                }
            }
        }
        return result
    }
}

// MARK: - Project folders

extension DerivedDataLocator {
    /// `.xcworkspace` bundles, then `.xcodeproj` bundles, directly inside `dir`, each group sorted by name.
    public static func projectContainers(in dir: URL) -> [URL] {
        let items = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        return items.filter { $0.pathExtension == "xcworkspace" } + items.filter { $0.pathExtension == "xcodeproj" }
    }

    /// DerivedData of a project folder (DESIGN §5.2): for each workspace or project in `dir`, its workspace settings,
    /// the custom location and the default root are searched for a child whose `info.plist` `WorkspacePath` equals
    /// it. Nil when `dir` holds no workspace or project; otherwise every directory searched is listed.
    public static func locateProject(in dir: URL,
                                     home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                     customLocation: @escaping @Sendable () -> String? = readCustomLocation)
        -> DerivedDataResolution? {
        let containers = projectContainers(in: dir)
        guard !containers.isEmpty else { return nil }
        let custom = customLocation()  // probed once, not per container
        var searched: [SearchedDirectory] = []
        for container in containers {
            let hit = DerivedDataLocator(workspace: container, home: home, customLocation: { custom }).locate()
            searched += hit.searched
            if hit.buildDir != nil {
                return DerivedDataResolution(buildDir: hit.buildDir, derivedData: hit.derivedData, source: hit.source,
                                             searched: searched)
            }
        }
        return DerivedDataResolution(buildDir: nil, derivedData: nil, source: nil, searched: searched)
    }
}
