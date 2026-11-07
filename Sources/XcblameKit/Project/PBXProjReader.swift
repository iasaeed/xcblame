import Foundation

/// Reads one `.xcodeproj` (OpenStep `project.pbxproj`, objectVersion 46–90) through `PropertyListSerialization`.
/// Read-only: the only other disk access is listing synchronized folders and `stat`ing resource files.
struct PBXProjReader {
    struct Result {
        var project: ProjectModel.Project
        /// This project's package references (not deduplicated across projects); local ones without a manifest yet.
        var packages: [ProjectModel.PackageReference]
        /// `XCSwiftPackageProductDependency` names without a `package` key (local packages), to consumer targets.
        var unboundProducts: [(product: String, target: String)]
        /// Some target has a `[CP] …` (CocoaPods) script phase.
        var hasCocoaPodsPhases: Bool
        var notes: [String]
    }

    typealias Object = [String: Any]

    /// Files over this size count toward `BuildPhase.resources(largeFileBytes:)` (ProjectModel doc comment).
    static let largeResourceBytes: Int64 = 10 * 1024 * 1024

    static let sourceExtensions: Set<String> = ["swift", "c", "m", "mm", "cpp", "cc", "cxx", "c++"]
    static let cExtensions: Set<String> = ["c", "m", "mm", "cpp", "cc", "cxx", "c++"]
    /// Folder-like resources counted as one item and measured as a whole.
    static let bundleExtensions: Set<String> = ["xcassets", "bundle", "xcdatamodeld", "xcdatamodel", "framework",
                                                "xcframework", "scnassets", "rcproject", "mlpackage", "mlmodelc",
                                                "docc", "storekit", "xcstrings", "playground", "app", "appex"]
    static let ignoredSyncExtensions: Set<String> = ["h", "hh", "hpp", "pch", "modulemap", "xcconfig", "entitlements"]

    static let knownISAs: Set<String> = [
        "PBXProject", "PBXBuildFile", "PBXFileReference", "PBXReferenceProxy", "PBXGroup", "PBXVariantGroup",
        "XCVersionGroup", "PBXNativeTarget", "PBXAggregateTarget", "PBXLegacyTarget", "PBXSourcesBuildPhase",
        "PBXResourcesBuildPhase", "PBXFrameworksBuildPhase", "PBXHeadersBuildPhase", "PBXCopyFilesBuildPhase",
        "PBXShellScriptBuildPhase", "PBXRezBuildPhase", "PBXAppleScriptBuildPhase", "PBXBuildRule",
        "PBXContainerItemProxy", "PBXTargetDependency", "XCBuildConfiguration", "XCConfigurationList",
        "XCRemoteSwiftPackageReference", "XCLocalSwiftPackageReference", "XCSwiftPackageProductDependency",
        "PBXFileSystemSynchronizedRootGroup", "PBXFileSystemSynchronizedBuildFileExceptionSet",
        "PBXFileSystemSynchronizedGroupBuildPhaseMembershipExceptionSet", "PBXBuildStyle",
    ]

    let xcodeproj: URL
    let objects: [String: Any]
    let rootID: String
    let srcRoot: URL
    let objectVersion: Int?
    private var parents: [String: String] = [:]
    private var pathMemo: [String: URL?] = [:]
    private var notes: [String] = []
    private var xcconfigCache: XCConfigCache

    /// Reads `<xcodeproj>/project.pbxproj`. Throws `notImplemented` for a `project.xcproj`-only project (MV-4) and
    /// `projectUnreadable` for a missing or corrupt file.
    static func read(xcodeproj: URL, xcconfigCache: XCConfigCache) throws -> Result {
        var reader = try PBXProjReader(xcodeproj: xcodeproj.standardizedFileURL, xcconfigCache: xcconfigCache)
        return reader.read()
    }

    private init(xcodeproj: URL, xcconfigCache: XCConfigCache) throws {
        let fm = FileManager.default
        let pbxproj = xcodeproj.appendingPathComponent("project.pbxproj")
        guard fm.fileExists(atPath: pbxproj.path) else {
            if fm.fileExists(atPath: xcodeproj.appendingPathComponent("project.xcproj").path) {
                throw XcblameError.notImplemented("project.xcproj read lands after MV-4 (\(xcodeproj.lastPathComponent) "
                    + "uses the Xcode 27.2 JSON project format, which this build cannot read yet)")
            }
            throw XcblameError.projectUnreadable("\(xcodeproj.path) has no project.pbxproj")
        }
        let data: Data
        do { data = try Data(contentsOf: pbxproj) } catch {
            throw XcblameError.projectUnreadable("\(pbxproj.path) is not readable: \(error.localizedDescription)")
        }
        let plist: Any
        do { plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) } catch {
            throw XcblameError.projectUnreadable("\(pbxproj.path) is not a valid project file: \(error.localizedDescription)")
        }
        guard let root = plist as? Object, let objects = root["objects"] as? [String: Any],
              let rootID = root["rootObject"] as? String, let project = objects[rootID] as? Object,
              project["isa"] as? String == "PBXProject" else {
            throw XcblameError.projectUnreadable("\(pbxproj.path) has no PBXProject root object")
        }
        self.xcodeproj = xcodeproj
        self.objects = objects
        self.rootID = rootID
        self.objectVersion = (root["objectVersion"] as? String).flatMap { Int($0) }
        let dir = xcodeproj.deletingLastPathComponent()
        let projectDir = project["projectDirPath"] as? String ?? ""
        srcRoot = (projectDir.isEmpty ? dir : projectDir.hasPrefix("/") ? URL(fileURLWithPath: projectDir)
            : dir.appendingPathComponent(projectDir)).standardizedFileURL
        self.xcconfigCache = xcconfigCache
        for (id, value) in objects {
            guard let object = value as? Object, let children = object["children"] as? [String] else { continue }
            for child in children { parents[child] = id }
        }
    }

    private mutating func read() -> Result {
        let project = object(rootID)!
        let name = xcodeproj.deletingPathExtension().lastPathComponent
        noteUnknownISAs()

        let projectConfigs = configurations(project["buildConfigurationList"], owner: "project \(name)")
        let projectList = object(project["buildConfigurationList"])
        var model = ProjectModel.Project(path: xcodeproj, name: name, objectVersion: objectVersion,
                                         configurations: projectConfigs.map(\.name),
                                         defaultConfiguration: projectList.flatMap { $0["defaultConfigurationName"] as? String })
        for config in projectConfigs {
            model.projectSettings[config.name] = config.settings
            if let url = config.xcconfig { model.projectXCConfig[config.name] = url }
        }

        // Package references and which product dependency belongs to which.
        var packages: [ProjectModel.PackageReference] = []
        var packageIndex: [String: Int] = [:]
        for id in strings(project, "packageReferences") {
            guard let ref = object(id), let reference = packageReference(ref, id: id) else { continue }
            packageIndex[id] = packages.count
            packages.append(reference)
        }
        // Before Xcode 15 a local package was a folder file reference (`lastKnownFileType = wrapper` or `folder`).
        var folderPackages: [URL] = []
        for (id, value) in objects {
            guard let ref = value as? Object, ref["isa"] as? String == "PBXFileReference",
                  ["wrapper", "folder"].contains(ref["lastKnownFileType"] as? String ?? ""),
                  let dir = path(of: id),
                  FileManager.default.fileExists(atPath: dir.appendingPathComponent("Package.swift").path) else { continue }
            folderPackages.append(dir)
        }
        for dir in Set(folderPackages).sorted(by: { $0.path < $1.path })
        where !packages.contains(where: { $0.path?.path == dir.path }) {
            packages.append(ProjectModel.PackageReference(url: nil, path: dir, requirement: .local))
        }

        var hasCocoaPodsPhases = false
        var unbound: [(String, String)] = []
        for targetID in strings(project, "targets") {
            guard let raw = object(targetID) else { continue }
            let target = self.target(raw, id: targetID, projectConfigs: projectConfigs)
            if target.phases.contains(where: {
                if case let .shellScript(phase) = $0 { return phase.name.hasPrefix("[CP]") } else { return false }
            }) {
                hasCocoaPodsPhases = true
            }
            for depID in strings(raw, "packageProductDependencies") {
                guard let dep = object(depID), let product = dep["productName"] as? String else { continue }
                if let packageID = dep["package"] as? String, let index = packageIndex[packageID] {
                    if !packages[index].products.contains(product) { packages[index].products.append(product) }
                    if !packages[index].consumers.contains(target.name) { packages[index].consumers.append(target.name) }
                } else {
                    unbound.append((product, target.name))
                }
            }
            model.targets.append(target)
        }
        return Result(project: model, packages: packages, unboundProducts: unbound,
                      hasCocoaPodsPhases: hasCocoaPodsPhases, notes: notes)
    }

    // MARK: - Targets

    private mutating func target(_ raw: Object, id: String,
                                 projectConfigs: [(name: String, settings: [String: SettingValue], xcconfig: URL?)])
        -> ProjectModel.Target {
        let name = raw["name"] as? String ?? raw["productName"] as? String ?? id
        let productType = raw["productType"] as? String ?? ""
        var target = ProjectModel.Target(id: id, name: name, productType: productType)
        let configs = configurations(raw["buildConfigurationList"], owner: "target \(name)")
        for config in configs {
            target.settings[config.name] = config.settings
            if let url = config.xcconfig { target.xcconfig[config.name] = url }
        }

        // Synchronized folders (objectVersion 77+): scanned on disk, membership exceptions for this target removed.
        var sync = SyncScan()
        for groupID in strings(raw, "fileSystemSynchronizedGroups") {
            guard let group = object(groupID), let folder = path(of: groupID) else { continue }
            var excluded: Set<String> = []
            for exceptionID in strings(group, "exceptions") {
                guard let exception = object(exceptionID), exception["target"] as? String == id else { continue }
                excluded.formUnion(strings(exception, "membershipExceptions"))
            }
            sync.scan(folder, excluded: excluded)
        }
        var addedSync = false
        var addedSyncResources = false

        for phaseID in strings(raw, "buildPhases") {
            guard let phase = object(phaseID), let isa = phase["isa"] as? String else { continue }
            switch isa {
            case "PBXShellScriptBuildPhase":
                target.phases.append(.shellScript(shellScript(phase, id: phaseID)))
            case "PBXSourcesBuildPhase":
                var count = 0
                for buildFileID in strings(phase, "files") {
                    count += 1
                    guard let ext = fileExtension(ofBuildFile: buildFileID) else { continue }
                    if ext == "swift" { target.hasSwiftSources = true }
                    if Self.cExtensions.contains(ext) { target.hasCSources = true }
                }
                if !addedSync {
                    count += sync.sources
                    addedSync = true
                }
                target.phases.append(.sources(count: count))
            case "PBXResourcesBuildPhase":
                var count = 0
                var large: Int64 = 0
                var measured = false
                for buildFileID in strings(phase, "files") {
                    count += 1
                    guard let buildFile = object(buildFileID), let ref = buildFile["fileRef"] as? String,
                          let url = path(of: ref) else { continue }
                    measured = true
                    large += Self.largeBytes(at: url)
                }
                if !addedSyncResources {
                    count += sync.resources
                    large += sync.largeBytes
                    measured = measured || sync.resources > 0
                    addedSyncResources = true
                }
                target.phases.append(.resources(count: count, largeFileBytes: measured || count == 0 ? large : nil))
            default:
                target.phases.append(.other(name: isa))
            }
        }
        if sync.hasSwift { target.hasSwiftSources = true }
        if sync.hasC { target.hasCSources = true }

        for depID in strings(raw, "dependencies") {
            guard let dep = object(depID) else { continue }
            if let other = object(dep["target"]), let otherName = other["name"] as? String {
                target.dependencies.append(otherName)
            } else if let proxy = object(dep["targetProxy"]), let info = proxy["remoteInfo"] as? String {
                target.dependencies.append(info)
            } else if let depName = dep["name"] as? String {
                target.dependencies.append(depName)
            } else if let product = object(dep["productRef"]), let productName = product["productName"] as? String {
                target.dependencies.append(productName)
            }
        }
        target.packageProducts = strings(raw, "packageProductDependencies").compactMap {
            object($0)?["productName"] as? String
        }
        target.isTest = productType.contains("unit-test") || productType.contains("ui-testing")
        target.frameworkKind = frameworkKind(productType: productType, target: target, projectConfigs: projectConfigs)
        target.hasBridgingHeader = hasSetting("SWIFT_OBJC_BRIDGING_HEADER", target: target, projectConfigs: projectConfigs)
        return target
    }

    private func shellScript(_ phase: Object, id: String) -> ProjectModel.ShellScriptPhase {
        let script: String
        if let text = phase["shellScript"] as? String {
            script = text
        } else if let lines = phase["shellScript"] as? [String] {
            script = lines.joined(separator: "\n")
        } else {
            script = ""
        }
        return ProjectModel.ShellScriptPhase(
            id: id, name: phase["name"] as? String ?? "Run Script", shellScript: script,
            inputPaths: strings(phase, "inputPaths"), outputPaths: strings(phase, "outputPaths"),
            inputFileListPaths: strings(phase, "inputFileListPaths"),
            outputFileListPaths: strings(phase, "outputFileListPaths"),
            alwaysOutOfDate: phase["alwaysOutOfDate"] as? String == "1",
            runOnlyForDeploymentPostprocessing: phase["runOnlyForDeploymentPostprocessing"] as? String == "1")
    }

    private func frameworkKind(productType: String, target: ProjectModel.Target,
                               projectConfigs: [(name: String, settings: [String: SettingValue], xcconfig: URL?)])
        -> ProjectModel.Target.FrameworkKind? {
        switch productType {
        case "com.apple.product-type.library.static", "com.apple.product-type.framework.static":
            return .static
        case "com.apple.product-type.library.dynamic":
            return .dynamic
        case "com.apple.product-type.framework":
            let machO = firstValue("MACH_O_TYPE", target: target, projectConfigs: projectConfigs)
            return machO == "staticlib" ? .static : .dynamic
        default:
            return nil
        }
    }

    /// The unconditional value of `key` at the most specific level that sets it, for the first configuration (in
    /// list order) where any level does: target settings, target xcconfig, project settings, project xcconfig.
    private func firstValue(_ key: String, target: ProjectModel.Target,
                            projectConfigs: [(name: String, settings: [String: SettingValue], xcconfig: URL?)]) -> String? {
        let names = projectConfigs.map(\.name)
        for config in names + target.settings.keys.sorted().filter({ !names.contains($0) }) {
            if let v = target.settings[config]?[key]?.raw { return v }
            if let url = target.xcconfig[config], let v = xcconfigCache.flattened(url)[key]?.raw { return v }
            let project = projectConfigs.first { $0.name == config }
            if let v = project?.settings[key]?.raw { return v }
            if let url = project?.xcconfig, let v = xcconfigCache.flattened(url)[key]?.raw { return v }
        }
        return nil
    }

    /// `key` set to a non-empty value (unconditionally or under a condition) at any level in any configuration.
    private func hasSetting(_ key: String, target: ProjectModel.Target,
                            projectConfigs: [(name: String, settings: [String: SettingValue], xcconfig: URL?)]) -> Bool {
        func set(_ value: SettingValue?) -> Bool {
            guard let value else { return false }
            return !(value.raw ?? "").isEmpty || (value.conditions ?? [:]).values.contains { !$0.isEmpty }
        }
        if target.settings.values.contains(where: { set($0[key]) }) { return true }
        if projectConfigs.contains(where: { set($0.settings[key]) }) { return true }
        let files = Array(target.xcconfig.values) + projectConfigs.compactMap(\.xcconfig)
        return files.contains { set(xcconfigCache.flattened($0)[key]) }
    }

    // MARK: - Configurations

    private mutating func configurations(_ listID: Any?, owner: String)
        -> [(name: String, settings: [String: SettingValue], xcconfig: URL?)] {
        guard let list = object(listID) else { return [] }
        return strings(list, "buildConfigurations").compactMap { id in
            guard let config = object(id), let name = config["name"] as? String else { return nil }
            let settings = Self.settings(config["buildSettings"] as? [String: Any] ?? [:])
            var xcconfig: URL?
            if let ref = config["baseConfigurationReference"] as? String {
                xcconfig = path(of: ref)
                if xcconfig == nil { notes.append("\(owner) \(name): baseConfigurationReference \(ref) does not resolve to a file path") }
            } else if let anchor = config["baseConfigurationReferenceAnchor"] as? String,
                      let relative = config["baseConfigurationReferenceRelativePath"] as? String,
                      let folder = path(of: anchor) {
                xcconfig = folder.appendingPathComponent(relative).standardizedFileURL
            }
            if let url = xcconfig, !FileManager.default.fileExists(atPath: url.path) {
                let note = "xcconfig not found: \(url.path) (\(owner) \(name))"
                if !notes.contains(note) { notes.append(note) }
            }
            return (name, settings, xcconfig)
        }
    }

    /// `buildSettings` → base key to value; conditional keys (`KEY[sdk=…]`) go to `SettingValue.conditions`, arrays
    /// are joined with single spaces (elements containing whitespace double-quoted).
    static func settings(_ dict: [String: Any]) -> [String: SettingValue] {
        var out: [String: SettingValue] = [:]
        for key in dict.keys.sorted() {
            guard let (base, condition) = XCConfigReader.splitConditionalKey(key) else { continue }
            XCConfigReader.assign(&out, key: base, condition: condition, value: settingText(dict[key]!))
        }
        return out
    }

    static func settingText(_ value: Any) -> String {
        if let s = value as? String { return s }
        if let array = value as? [Any] {
            return array.map { element -> String in
                let s = settingText(element)
                return s.contains(where: \.isWhitespace) ? "\"\(s)\"" : s
            }.joined(separator: " ")
        }
        return "\(value)"
    }

    // MARK: - Packages

    private mutating func packageReference(_ ref: Object, id: String) -> ProjectModel.PackageReference? {
        switch ref["isa"] as? String {
        case "XCRemoteSwiftPackageReference":
            guard let url = ref["repositoryURL"] as? String else { return nil }
            let req = ref["requirement"] as? [String: Any] ?? [:]
            let kind = req["kind"] as? String ?? ""
            let requirement: ProjectModel.PackageReference.Requirement
            switch kind {
            case "exactVersion": requirement = .exact(req["version"] as? String ?? "")
            case "upToNextMajorVersion": requirement = .upToNextMajor(req["minimumVersion"] as? String ?? "")
            case "upToNextMinorVersion": requirement = .upToNextMinor(req["minimumVersion"] as? String ?? "")
            case "versionRange":
                requirement = .range(from: req["minimumVersion"] as? String ?? "", to: req["maximumVersion"] as? String ?? "")
            case "branch": requirement = .branch(req["branch"] as? String ?? "")
            case "revision": requirement = .revision(req["revision"] as? String ?? "")
            default:
                notes.append("package \(url): requirement kind \"\(kind)\" not understood; read as upToNextMajor")
                requirement = .upToNextMajor(req["minimumVersion"] as? String ?? "")
            }
            return ProjectModel.PackageReference(url: url, path: nil, requirement: requirement)
        case "XCLocalSwiftPackageReference":
            guard let relative = ref["relativePath"] as? String else { return nil }
            let url = relative.hasPrefix("/") ? URL(fileURLWithPath: relative) : srcRoot.appendingPathComponent(relative)
            return ProjectModel.PackageReference(url: nil, path: url.standardizedFileURL, requirement: .local)
        default:
            return nil
        }
    }

    // MARK: - Paths

    /// Absolute location of a file reference or group: `<group>` walks up the parent groups to the project root,
    /// `SOURCE_ROOT` is the project root, `<absolute>` is the path; build-product and SDK trees resolve to nil.
    private mutating func path(of id: String) -> URL? {
        if let memo = pathMemo[id] { return memo }
        pathMemo[id] = .some(nil)  // cycle guard
        var result: URL?
        if let object = object(id) {
            let path = object["path"] as? String
            switch object["sourceTree"] as? String ?? "<group>" {
            case "<absolute>":
                result = path.map { URL(fileURLWithPath: $0) }
            case "SOURCE_ROOT":
                result = path.map { srcRoot.appendingPathComponent($0) } ?? srcRoot
            case "<group>":
                var base: URL? = srcRoot
                if let parent = parents[id] { base = self.path(of: parent) }
                if let base { result = path.map { $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : base.appendingPathComponent($0) } ?? base }
            default:
                result = nil
            }
        }
        result = result?.standardizedFileURL
        pathMemo[id] = .some(result)
        return result
    }

    private func fileExtension(ofBuildFile id: String) -> String? {
        guard let buildFile = object(id), let ref = object(buildFile["fileRef"]) else { return nil }
        let name = ref["path"] as? String ?? ref["name"] as? String ?? ""
        let ext = (name as NSString).pathExtension.lowercased()
        if !ext.isEmpty { return ext }
        switch ref["lastKnownFileType"] as? String ?? ref["explicitFileType"] as? String {
        case "sourcecode.swift": return "swift"
        case "sourcecode.c.objc": return "m"
        case "sourcecode.c.c": return "c"
        case "sourcecode.cpp.objcpp": return "mm"
        case "sourcecode.cpp.cpp": return "cpp"
        default: return nil
        }
    }

    /// Bytes in files over `largeResourceBytes` at `url` (a file, or every file under a folder resource).
    static func largeBytes(at url: URL) -> Int64 {
        let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey]
        guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return 0 }
        if values.isRegularFile == true {
            let size = Int64(values.fileSize ?? 0)
            return size > largeResourceBytes ? size : 0
        }
        var total: Int64 = 0
        let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys)
        while let file = walker?.nextObject() as? URL {
            guard let v = try? file.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
            let size = Int64(v.fileSize ?? 0)
            if size > largeResourceBytes { total += size }
        }
        return total
    }

    // MARK: - Objects

    private func object(_ id: Any?) -> Object? {
        (id as? String).flatMap { objects[$0] as? Object }
    }

    private func strings(_ object: Object, _ key: String) -> [String] {
        object[key] as? [String] ?? []
    }

    private mutating func noteUnknownISAs() {
        var unknown: [String: Int] = [:]
        for value in objects.values {
            guard let isa = (value as? Object)?["isa"] as? String, !Self.knownISAs.contains(isa) else { continue }
            unknown[isa, default: 0] += 1
        }
        for (isa, count) in unknown.sorted(by: { $0.key < $1.key }) {
            notes.append("\(xcodeproj.lastPathComponent): ignored \(count) object(s) of unknown isa \(isa)")
        }
    }
}

/// Member files of synchronized root groups, counted the way the Sources and Copy Bundle Resources phases would.
private struct SyncScan {
    var sources = 0
    var resources = 0
    var largeBytes: Int64 = 0
    var hasSwift = false
    var hasC = false

    mutating func scan(_ folder: URL, excluded: Set<String>) {
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey]
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys,
                                                          options: [.skipsHiddenFiles]) else { return }
        let prefix = folder.standardizedFileURL.path + "/"
        while let url = walker.nextObject() as? URL {
            let full = url.standardizedFileURL.path
            let relative = full.hasPrefix(prefix) ? String(full.dropFirst(prefix.count)) : url.lastPathComponent
            if excluded.contains(relative) || excluded.contains(where: { relative.hasPrefix($0 + "/") }) {
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true { walker.skipDescendants() }
                continue
            }
            let ext = url.pathExtension.lowercased()
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            if isDirectory {
                if PBXProjReader.bundleExtensions.contains(ext) {
                    walker.skipDescendants()
                    resources += 1
                    largeBytes += PBXProjReader.largeBytes(at: url)
                }
                continue
            }
            if PBXProjReader.sourceExtensions.contains(ext) {
                sources += 1
                if ext == "swift" { hasSwift = true } else { hasC = true }
            } else if !PBXProjReader.ignoredSyncExtensions.contains(ext), url.lastPathComponent != "Info.plist" {
                resources += 1
                largeBytes += PBXProjReader.largeBytes(at: url)
            }
        }
    }
}

/// Parsed and flattened xcconfigs shared by every project of one load.
final class XCConfigCache {
    private var flat: [URL: [String: SettingValue]] = [:]

    /// `XCConfigReader.flatten` of `url`, memoized; empty for a missing file.
    func flattened(_ url: URL) -> [String: SettingValue] {
        let key = url.standardizedFileURL
        if let hit = flat[key] { return hit }
        let value = XCConfigReader.flatten(url: key)
        flat[key] = value
        return value
    }
}
