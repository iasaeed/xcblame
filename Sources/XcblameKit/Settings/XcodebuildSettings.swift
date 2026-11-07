import Foundation

/// `xcodebuild -showBuildSettings -json` without writing into the project.
///
/// Opening a project with xcodebuild (even `-list`) creates `<project>.xcodeproj/project.xcworkspace/xcshareddata/
/// swiftpm/configuration/` when missing, writes `Package.resolved` there when packages resolve, and creates
/// `.swiftpm/xcode/` in local packages. So xcodebuild never opens the container itself: it opens a scratch workspace
/// in the cache that references every project by absolute path and holds a generated scheme building every project
/// target (one call lists all targets of all projects, as cheap as `-alltargets` on the 200-target fixture, which
/// cannot take `-derivedDataPath`), plus a copy of the container's `Package.resolved`. Projects without packages run
/// under `sandbox-exec` with writes denied below the project; SwiftPM sandboxes manifest evaluation itself and nested
/// sandboxes are refused, so package projects run unsandboxed and a guard removes the empty `.swiftpm/` trees
/// xcodebuild leaves in local packages (restoring the folder's mtime).
enum XcodebuildSettings {
    static let schemeName = "xcblame-settings"

    struct Outcome: Sendable {
        var targets: [String: [String: String]]?
        var notes: [String]
        var timedOut = false
    }

    /// The scratch folder for `project`: `OracleCache.directory` under `cacheHome` (outside the repository), or a
    /// temporary folder removed after the run.
    static func scratch(cacheHome: URL?, project: ProjectModel) -> (url: URL, temporary: Bool) {
        if let cacheHome { return (OracleCache.directory(for: project.container.url, home: cacheHome), false) }
        return (FileManager.default.temporaryDirectory.appendingPathComponent("xcblame-settings-\(UUID().uuidString)"), true)
    }

    /// Writes the scratch workspace and its scheme; returns the workspace and the scheme to pass. Throws when there
    /// is nothing xcodebuild could list or the cache folder is not writable.
    /// The scratch workspace, its all-targets scheme, and one scheme per platform group with the destination it runs
    /// with (a single group reuses the all-targets scheme).
    struct Prepared {
        var workspace: URL
        var scheme: String
        var groups: [(scheme: String, destination: String?, targets: [String])]
    }

    static func prepare(project: ProjectModel, scheme: String?, in dir: URL) throws -> Prepared {
        let fm = FileManager.default
        let workspace = dir.appendingPathComponent("Settings.xcworkspace")
        let shared = workspace.appendingPathComponent("xcshareddata")
        try fm.createDirectory(at: shared.appendingPathComponent("xcschemes"), withIntermediateDirectories: true)
        try fm.createDirectory(at: shared.appendingPathComponent("swiftpm"), withIntermediateDirectories: true)

        let refs = project.projects.map {
            "   <FileRef location = \"absolute:\(xml($0.path.standardizedFileURL.path))\"></FileRef>\n"
        }.joined()
        try Data("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<Workspace version = \"1.0\">\n\(refs)</Workspace>\n".utf8)
            .write(to: workspace.appendingPathComponent("contents.xcworkspacedata"), options: .atomic)

        // The container's pins, so `-disableAutomaticPackageResolution` resolves what the project resolves.
        let resolved = shared.appendingPathComponent("swiftpm/Package.resolved")
        try? fm.removeItem(at: resolved)
        if let source = packageResolved(project) { try fm.copyItem(at: source, to: resolved) }

        let entries = project.projects.flatMap { proj in
            proj.targets.map { target in
                """
                         <BuildActionEntry buildForRunning = "YES">
                            <BuildableReference BuildableIdentifier = "primary" BlueprintIdentifier = "\(xml(target.id))" \
                BlueprintName = "\(xml(target.name))" ReferencedContainer = "absolute:\(xml(proj.path.standardizedFileURL.path))">
                            </BuildableReference>
                         </BuildActionEntry>

                """
            }
        }
        guard !entries.isEmpty else {
            if let scheme { return Prepared(workspace: workspace, scheme: scheme, groups: [(scheme, nil, [])]) }
            throw XcblameError.readerFailure("no project targets and no scheme to list")
        }
        let text = """
            <?xml version="1.0" encoding="UTF-8"?>
            <Scheme version = "1.7">
               <BuildAction parallelizeBuildables = "YES" buildImplicitDependencies = "NO">
                  <BuildActionEntries>
            \(entries.joined())      </BuildActionEntries>
               </BuildAction>
            </Scheme>

            """
        try Data(text.utf8).write(to: shared.appendingPathComponent("xcschemes/\(schemeName).xcscheme"), options: .atomic)

        // One destination per platform, so an iOS dependency target is not evaluated for macOS / Mac Catalyst.
        let platforms = platformGroups(project)
        if platforms.count == 1 {
            return Prepared(workspace: workspace, scheme: schemeName,
                            groups: [(schemeName, platforms[0].destination, platforms[0].targets.map(\.target.name))])
        }
        var groups: [(scheme: String, destination: String?, targets: [String])] = []
        for (index, group) in platforms.enumerated() {
            let name = "\(schemeName)-\(index)"
            let body = group.targets.map { item in
                """
                         <BuildActionEntry buildForRunning = "YES">
                            <BuildableReference BuildableIdentifier = "primary" BlueprintIdentifier = "\(xml(item.target.id))" \
                BlueprintName = "\(xml(item.target.name))" ReferencedContainer = "absolute:\(xml(item.project.path.standardizedFileURL.path))">
                            </BuildableReference>
                         </BuildActionEntry>

                """
            }.joined()
            let groupText = text.replacingOccurrences(of: entries.joined(), with: body)
            try Data(groupText.utf8).write(to: shared.appendingPathComponent("xcschemes/\(name).xcscheme"), options: .atomic)
            groups.append((name, group.destination, group.targets.map(\.target.name)))
        }
        return Prepared(workspace: workspace, scheme: schemeName, groups: groups)
    }

    /// `-destination` for a written SDKROOT (or the first SUPPORTED_PLATFORMS word); nil when unknown or `auto`.
    static func destination(sdk: String?) -> String? {
        guard let sdk = sdk?.lowercased() else { return nil }
        let table: [(String, String)] = [("iphone", "iOS"), ("macosx", "macOS"), ("appletv", "tvOS"), ("watch", "watchOS"),
                                         ("xr", "visionOS")]
        return table.first { sdk.hasPrefix($0.0) }.map { "generic/platform=\($0.1)" }
    }

    /// Project targets grouped by their written platform (`SDKROOT`, else `SUPPORTED_PLATFORMS`, project level
    /// included), in project order; targets whose platform is unknown share a group without a destination.
    static func platformGroups(_ project: ProjectModel)
        -> [(destination: String?, targets: [(project: ProjectModel.Project, target: ProjectModel.Target)])] {
        var resolver = ProvenanceResolver(project: project)
        var groups: [(destination: String?, targets: [(project: ProjectModel.Project, target: ProjectModel.Target)])] = []
        for proj in project.projects {
            for target in proj.targets {
                let configuration = proj.configurations.first ?? "Debug"
                func written(_ key: String) -> String? {
                    resolver.chain(target: target.name, key: key, configuration: configuration)?
                        .last { $0.condition == nil }?.raw.trimmingCharacters(in: .whitespaces)
                }
                let sdk = written("SDKROOT").flatMap { $0 == "auto" ? nil : $0 }
                    ?? written("SUPPORTED_PLATFORMS")?.split(separator: " ").first.map(String.init)
                let destination = destination(sdk: sdk)
                if let index = groups.firstIndex(where: { $0.destination == destination }) {
                    groups[index].targets.append((proj, target))
                } else {
                    groups.append((destination, [(proj, target)]))
                }
            }
        }
        return groups
    }

    static func packageResolved(_ project: ProjectModel) -> URL? {
        var candidates: [URL] = []
        if case let .xcworkspace(url) = project.container {
            candidates.append(url.appendingPathComponent("xcshareddata/swiftpm/Package.resolved"))
        }
        candidates += project.projects.map {
            $0.path.appendingPathComponent("project.xcworkspace/xcshareddata/swiftpm/Package.resolved")
        }
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func usesPackages(_ project: ProjectModel) -> Bool {
        !project.packages.isEmpty || project.dependencyManagers.contains(.spm) || packageResolved(project) != nil
    }

    /// Local package folders (where xcodebuild creates `.swiftpm/`).
    static func localPackageDirs(_ project: ProjectModel) -> [URL] {
        project.packages.compactMap(\.path).map { $0.lastPathComponent == "Package.swift" ? $0.deletingLastPathComponent() : $0 }
    }

    /// The tool the oracle runs; `effectiveAll(xcodebuild:)` replaces it (tests that must not touch the network).
    static let defaultExecutable = "/usr/bin/xcodebuild"

    /// One configuration. `sandboxed` denies writes below the project (except `allowed`).
    /// `packages` is the `-clonedSourcePackagesDirPath` (default `dir/SourcePackages`; `sourcePackages` picks the
    /// container's own DerivedData checkouts when they exist).
    static func run(project: ProjectModel, configuration: String, workspace: URL, scheme: String, dir: URL,
                    sandboxed: Bool, skipPackageUpdates: Bool, timeout: TimeInterval, packages: URL? = nil,
                    destination: String? = nil, executable: String = defaultExecutable,
                    extraArguments: [String] = [], unsetEnvironment: [String] = []) -> ProcessOutput? {
        let derived = dir.appendingPathComponent("DerivedData-\(SettingsCache.sha256(configuration).prefix(8))")
        var argv = [executable, "-showBuildSettings", "-json", "-workspace", workspace.path,
                    "-scheme", scheme, "-configuration", configuration,
                    "-derivedDataPath", derived.path,
                    "-clonedSourcePackagesDirPath", (packages ?? dir.appendingPathComponent("SourcePackages")).path,
                    "-disableAutomaticPackageResolution",
                    "-skipPackagePluginValidation", "-skipMacroValidation", "-skipUnavailableActions"]
        // Saves ~1 s per call once the pinned checkouts are in the cache; a cold cache must fetch them.
        if skipPackageUpdates { argv.append("-skipPackageUpdates") }
        if let destination { argv += ["-destination", destination] }
        argv += extraArguments
        if sandboxed { argv = sandbox(project: project, allowing: dir) + argv }
        // Xcode's source control runs git in the working copy; without optional locks a status refresh never creates
        // `.git/index.lock` (one corpus project's `.git` mtime changed during an unsandboxed run; unverified cause).
        return runProcess(["/usr/bin/env"] + unsetEnvironment.flatMap { ["-u", $0] } + ["GIT_OPTIONAL_LOCKS=0"] + argv,
                          timeout: max(0.1, timeout))
    }

    /// `sandbox-exec` arguments denying writes below the project root, every project folder and every local package,
    /// except below `allowed` (the scratch folder, which may sit inside the project as `.xcblame/cache`). Later SBPL
    /// rules win, so the allow comes last.
    static func sandbox(project: ProjectModel, allowing allowed: URL) -> [String] {
        let denied = Set([project.root] + project.projects.map { $0.path.deletingLastPathComponent() }
            + localPackageDirs(project)).map(realPath).sorted()
        var profile = "(version 1)\n(allow default)\n"
        var params: [String] = []
        for (i, path) in denied.enumerated() {
            profile += "(deny file-write* (subpath (param \"DENY\(i)\")))\n"
            params += ["-D", "DENY\(i)=\(path)"]
        }
        profile += "(allow file-write* (subpath (param \"ALLOW\")))\n"
        params += ["-D", "ALLOW=\(realPath(allowed))"]
        return ["/usr/bin/sandbox-exec", "-p", profile] + params
    }

    /// The pinned package checkouts are already in the scratch folder.
    static func hasCheckouts(_ dir: URL) -> Bool {
        hasPackageCheckouts(dir.appendingPathComponent("SourcePackages"))
    }

    static func hasPackageCheckouts(_ sourcePackages: URL) -> Bool {
        !((try? FileManager.default.contentsOfDirectory(atPath: sourcePackages.appendingPathComponent("checkouts").path)) ?? []).isEmpty
    }

    /// The checkouts the project already has, so resolving needs no network: `<DerivedData>/SourcePackages` of the
    /// container's own DerivedData (Xcode's default root, the custom location or the workspace settings, matched by
    /// `WorkspacePath`, build logs or not), else a project-local one (`-derivedDataPath build/dd`, Flutter's
    /// `build/ios`) whose `info.plist` names the container or whose checkouts hold every pin of `Package.resolved`.
    /// Nil for projects without packages or without such a folder.
    // ponytail: reuses the user's checkouts read-only by contract (one configuration first, `-skipPackageUpdates`
    // always, never with changed pins); xcodebuild may still refresh SwiftPM state files there. upgrade: APFS clone.
    static func sourcePackages(_ project: ProjectModel, locate: (URL) -> URL? = derivedData) -> URL? {
        guard usesPackages(project) else { return nil }
        if let derived = locate(project.container.url) {
            let packages = derived.appendingPathComponent("SourcePackages")
            if hasPackageCheckouts(packages) { return packages }
        }
        return localSourcePackages(project)
    }

    /// The container's Xcode DerivedData with package checkouts, newest first: `DerivedDataLocator` roots (workspace
    /// settings, custom location, default), any child whose `info.plist` `WorkspacePath` is the container.
    static func derivedData(for container: URL) -> URL? {
        let locator = DerivedDataLocator(workspace: container)
        if let found = locator.locate().derivedData,
           hasPackageCheckouts(found.appendingPathComponent("SourcePackages")) { return found }
        var roots = locator.workspaceSettingsLocations(container)
        if let custom = locator.customLocation(), !custom.isEmpty {
            roots.append(URL(fileURLWithPath: NSString(string: custom).expandingTildeInPath))
        }
        roots.append(locator.home.appendingPathComponent("Library/Developer/Xcode/DerivedData"))
        let wanted = DerivedDataLocator.normalized(container.path)
        let matches = roots.flatMap { root in
            ((try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []).filter { child in
                (NSDictionary(contentsOf: child.appendingPathComponent("info.plist"))?["WorkspacePath"] as? String)
                    .map(DerivedDataLocator.normalized) == wanted
                    && hasPackageCheckouts(child.appendingPathComponent("SourcePackages"))
            }
        }
        return matches.max { modified($0) < modified($1) }
    }

    /// Target names more than one project uses (`ProjectModel.allTargets` qualifies them).
    static func sharedTargetNames(_ project: ProjectModel) -> Set<String> {
        Set(Dictionary(project.projects.flatMap { $0.targets.map { ($0.name, 1) } }, uniquingKeysWith: +)
            .filter { $0.value > 1 }.keys)
    }

    /// Folders skipped by every project walk (the write guard, the local checkout search).
    static let skippedFolders: Set<String> = [".git", ".build", "DerivedData", "node_modules", ".xcblame", "Pods"]

    /// A `SourcePackages` folder with checkouts within four levels of the project root whose parent `info.plist`
    /// names the container, else one whose checkouts hold every pin of the container's `Package.resolved`.
    static func localSourcePackages(_ project: ProjectModel) -> URL? {
        let fm = FileManager.default
        let wanted = DerivedDataLocator.normalized(project.container.url.path)
        let root = project.root.standardizedFileURL
        var queue: [(URL, Int)] = [(root, 0)]
        // Flutter keeps the iOS DerivedData next to the platform folder: `<app>/build/ios` for `<app>/ios`.
        let sibling = root.deletingLastPathComponent().appendingPathComponent("build")
        if !sibling.path.hasPrefix(root.path + "/"), FileManager.default.fileExists(atPath: sibling.path) {
            queue.append((sibling, 1))
        }
        var visited = 0
        var byPins: URL?
        while !queue.isEmpty, visited < 20_000 {
            let (dir, depth) = queue.removeFirst()
            for child in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])) ?? [] {
                visited += 1
                let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values?.isDirectory == true, values?.isSymbolicLink != true,
                      !skippedFolders.contains(child.lastPathComponent) || child.lastPathComponent == "DerivedData" else { continue }
                if child.lastPathComponent == "SourcePackages", hasPackageCheckouts(child) {
                    let owner = NSDictionary(contentsOf: child.deletingLastPathComponent().appendingPathComponent("info.plist"))?["WorkspacePath"] as? String
                    if owner.map(DerivedDataLocator.normalized) == wanted { return child }
                    if byPins == nil, pinsMatch(project, checkouts: child) == true { byPins = child }
                    continue
                }
                if depth < 4, !child.pathExtension.hasPrefix("xc"), child.pathExtension != "app" { queue.append((child, depth + 1)) }
            }
        }
        return byPins
    }

    /// `Package.resolved` pins (identity → revision); nil without the file or pins.
    static func pins(_ project: ProjectModel) -> [String: String]? {
        guard let file = packageResolved(project), let data = FileManager.default.contents(atPath: file.path),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let list = (root["pins"] as? [[String: Any]]) ?? ((root["object"] as? [String: Any])?["pins"] as? [[String: Any]]) ?? []
        var out: [String: String] = [:]
        for pin in list {
            let identity = (pin["identity"] as? String) ?? (pin["package"] as? String)
            let revision = (pin["state"] as? [String: Any])?["revision"] as? String
            if let identity, let revision { out[identity.lowercased()] = revision }
        }
        return out.isEmpty ? nil : out
    }

    /// The checkouts in `checkouts` (a `SourcePackages` folder) are at every revision `Package.resolved` pins
    /// (`workspace-state.json`): reusing them resolves nothing. Nil when the project pins nothing; false when the
    /// state file is missing or any pin differs (Xcode has not resolved the new pins yet).
    static func pinsMatch(_ project: ProjectModel, checkouts: URL) -> Bool? {
        guard let pins = pins(project) else { return nil }
        guard let state = stateRevisions(checkouts) else { return false }
        return pins.allSatisfy { state[$0.key] == $0.value }
    }

    /// `workspace-state.json` checkout revisions (identity → revision) of a `SourcePackages` folder; nil without it.
    static func stateRevisions(_ checkouts: URL) -> [String: String]? {
        guard let data = FileManager.default.contents(atPath: checkouts.appendingPathComponent("workspace-state.json").path),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let dependencies = (root["object"] as? [String: Any])?["dependencies"] as? [[String: Any]] else { return nil }
        var state: [String: String] = [:]
        for dependency in dependencies {
            let identity = ((dependency["packageRef"] as? [String: Any])?["identity"] as? String)?.lowercased()
            let checkout = (dependency["state"] as? [String: Any])?["checkoutState"] as? [String: Any]
            if let identity, let revision = checkout?["revision"] as? String { state[identity] = revision }
        }
        return state
    }

    /// The clone of `source` an earlier `doctor` left in `scratch` (same revisions), else nil; never copies.
    static func existingClone(of source: URL, in scratch: URL) -> URL? {
        let target = scratch.appendingPathComponent("SourcePackages")
        guard let revisions = stateRevisions(target), revisions == stateRevisions(source), hasPackageCheckouts(target) else {
            return nil
        }
        return target
    }

    /// Largest checkouts folder copied when the APFS clone is not possible.
    static let maxCheckoutCopyBytes: Int64 = 2 << 30

    /// The project's checkouts as a private copy in the scratch folder (`scratch/SourcePackages`): xcodebuild rewrites
    /// `workspace-state.json` in whatever it is given, so the user's folder is never passed. An APFS clone
    /// (`cp -c`, copy-on-write) first, a plain copy up to 2 GB otherwise. The copy is kept while the source's
    /// revisions are unchanged. Nil (with a note) when it cannot be made.
    static func clonedCheckouts(_ source: URL, into scratch: URL, notes: inout [String]) -> URL? {
        let fm = FileManager.default
        let target = scratch.appendingPathComponent("SourcePackages")
        if let revisions = stateRevisions(target), revisions == stateRevisions(source), hasPackageCheckouts(target) {
            return target
        }
        try? fm.removeItem(at: target)
        try? fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        if runProcess(["/bin/cp", "-c", "-R", source.path, target.path], timeout: 600)?.succeeded == true { return target }
        try? fm.removeItem(at: target)
        let size = OracleCache.size(of: source)
        guard size <= maxCheckoutCopyBytes else {
            notes.append("the project's package checkouts (\(source.path)) could not be cloned and are too large to copy "
                + "(\(size >> 20) MB): not used")
            return nil
        }
        if runProcess(["/bin/cp", "-R", source.path, target.path], timeout: 600)?.succeeded == true { return target }
        try? fm.removeItem(at: target)
        notes.append("the project's package checkouts (\(source.path)) could not be copied: not used")
        return nil
    }

    private static func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
    }

    /// `[{target, action, buildSettings}]` to target → settings (first entry per target and project). A target name
    /// several projects use is keyed `<PROJECT_NAME>/<target>` for each, as `ProjectModel.allTargets` names them:
    /// `qualified` (the model's shared names) decides even when one output lists the name once (platform groups).
    static func parse(_ data: Data, qualified: Set<String> = []) -> [String: [String: String]]? {
        var body = data
        if let start = data.firstIndex(of: UInt8(ascii: "[")), start != data.startIndex { body = data[start...] }
        guard let array = (try? JSONSerialization.jsonObject(with: body)) as? [[String: Any]] else { return nil }
        var entries: [(target: String, project: String, values: [String: String])] = []
        for entry in array {
            guard let target = entry["target"] as? String, let settings = entry["buildSettings"] as? [String: Any] else {
                continue
            }
            let project = settings["PROJECT_NAME"] as? String ?? ""
            guard !entries.contains(where: { $0.target == target && $0.project == project }) else { continue }
            var values: [String: String] = [:]
            values.reserveCapacity(settings.count)
            for (key, value) in settings {
                values[key] = value as? String ?? "\(value)"
            }
            entries.append((target, project, values))
        }
        let projectsPerName = Dictionary(entries.map { ($0.target, Set([$0.project])) }, uniquingKeysWith: { $0.union($1) })
        var out: [String: [String: String]] = [:]
        for entry in entries {
            let key = (projectsPerName[entry.target]?.count ?? 0) > 1 || qualified.contains(entry.target)
                ? entry.project + "/" + entry.target : entry.target
            if out[key] == nil { out[key] = entry.values }
        }
        return out
    }

    /// The first `error:` line of stderr (or its last line), for a fallback note.
    static func reason(_ output: ProcessOutput?) -> String {
        guard let output else { return "could not launch xcodebuild" }
        if output.timedOut { return "timed out" }
        let lines = output.stderrString.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        let line = lines.first { $0.contains("error:") } ?? lines.last ?? "exit \(output.exitStatus)"
        return String(line.prefix(240))
    }

    /// The kernel's path (`/private/var/…`; `resolvingSymlinksInPath` strips `/private`, which the sandbox never
    /// matches).
    static func realPath(_ url: URL) -> String {
        let path = url.standardizedFileURL.path
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private static func xml(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }
}

/// Undoes the empty folders an unsandboxed xcodebuild creates: before the run it snapshots every folder under the
/// container root and every local package root (nested packages included, `skippedFolders` and `skipping` left out,
/// at most `limit` entries), after it removes the new folders that hold nothing but empty folders and restores their
/// parents' mtimes. A new folder with any file in it is reported, never deleted.
struct WriteGuard {
    static let limit = 200_000
    private let roots: [URL]
    private let skipping: Set<String>
    /// Folder path to its mtime before the run.
    private var before: [String: timespec] = [:]
    private(set) var truncated = false

    init(roots: [URL], skipping: [URL] = []) {
        let paths = Set(roots.map { $0.standardizedFileURL.path })
        // A root inside another root is walked with it, unless the walk skips a folder on the way (a reused
        // `DerivedData/SourcePackages` is watched as a root of its own).
        func reached(_ path: String, from root: String) -> Bool {
            guard path.hasPrefix(root + "/") else { return false }
            return !path.dropFirst(root.count + 1).split(separator: "/").dropLast()
                .contains { XcodebuildSettings.skippedFolders.contains(String($0)) }
                && !XcodebuildSettings.skippedFolders.contains((path as NSString).lastPathComponent)
        }
        self.roots = paths.filter { path in !paths.contains { $0 != path && reached(path, from: $0) } }.sorted()
            .map { URL(fileURLWithPath: $0) }
        self.skipping = Set(skipping.map { $0.standardizedFileURL.path })
        var seen: [String: timespec] = [:]
        truncated = !walk { path, mtime in seen[path] = mtime }
        before = seen
    }

    /// Tests: behave as if the snapshot had hit `limit`.
    mutating func forceTruncatedForTesting() { truncated = true }

    /// Visits every folder under the roots; false when the walk stopped at `limit`.
    private func walk(_ visit: (String, timespec) -> Void) -> Bool {
        let fm = FileManager.default
        var count = 0
        for root in roots {
            var info = stat()
            guard stat(root.path, &info) == 0 else { continue }
            visit(root.path, info.st_mtimespec)
            var stack = [root.path]
            while let dir = stack.popLast() {
                for name in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] {
                    count += 1
                    if count > Self.limit { return false }
                    let path = dir + "/" + name
                    guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
                          !XcodebuildSettings.skippedFolders.contains(name), !skipping.contains(path) else { continue }
                    visit(path, info.st_mtimespec)
                    stack.append(path)
                }
            }
        }
        return true
    }

    /// What it removed (paths) and what it left in place (notes).
    func restore() -> (removed: [String], notes: [String]) {
        var now: [String] = []
        _ = walk { path, _ in now.append(path) }
        let fresh = now.filter { before[$0] == nil }
        // The topmost new folders: their parent existed before.
        let tops = fresh.filter { before[($0 as NSString).deletingLastPathComponent] != nil }.sorted()
        var removed: [String] = []
        var notes: [String] = []
        // A capped snapshot cannot tell new folders from ones the first walk never reached: report, never delete.
        guard !truncated else {
            return ([], ["write guard watched the first \(Self.limit) entries only, so nothing was removed"]
                + tops.map { "xcodebuild may have created \($0) (left in place)" })
        }
        for path in tops {
            let url = URL(fileURLWithPath: path)
            if Self.onlyEmptyFolders(url), (try? FileManager.default.removeItem(at: url)) != nil {
                removed.append(path)
                let parent = (path as NSString).deletingLastPathComponent
                if let mtime = before[parent] {
                    // Nanosecond-exact, so the folder looks untouched.
                    _ = utimensat(AT_FDCWD, parent, [timespec(tv_sec: 0, tv_nsec: Int(UTIME_OMIT)), mtime], 0)
                }
            } else {
                notes.append("xcodebuild wrote \(path) (left in place)")
            }
        }
        return (removed, notes)
    }

    static func onlyEmptyFolders(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { return false }
        let children = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        return children.allSatisfy { onlyEmptyFolders(url.appendingPathComponent($0)) }
    }
}
