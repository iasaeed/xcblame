import Foundation

/// `ProjectModel.load`: puts the readers together for a workspace, a project or a package. Reads only; never runs
/// `xcodebuild` or `swift package` (the settings oracle is Lane B's).
enum ProjectModelLoader {
    static func load(container: URL, scheme: String?) throws -> ProjectModel {
        let fm = FileManager.default
        var url = container.standardizedFileURL
        guard fm.fileExists(atPath: url.path) else {
            throw XcblameError.projectNotFound("\(url.path) does not exist")
        }
        // A plain folder: the container ProjectLocator picks in it.
        if !["xcworkspace", "xcodeproj"].contains(url.pathExtension), url.lastPathComponent != "Package.swift",
           let found = ProjectLocator.find(startingAt: url) {
            url = found
        }
        var state = State(scheme: scheme)
        let kind: ProjectModel.Container
        let root: URL

        switch url.pathExtension {
        case "xcworkspace":
            kind = .xcworkspace(url)
            root = url.deletingLastPathComponent()
            for ref in try WorkspaceReader.references(of: url) {
                if ref.pathExtension == "xcodeproj" {
                    if ref.lastPathComponent == "Pods.xcodeproj" {
                        state.podsProject = ref
                        state.notes.append("\(ref.lastPathComponent) is CocoaPods-generated; its targets are not read")
                        continue
                    }
                    guard fm.fileExists(atPath: ref.path) else {
                        state.notes.append("workspace references \(ref.path), which does not exist")
                        continue
                    }
                    do {
                        try state.readProject(ref)
                    } catch let error as XcblameError {
                        if case .notImplemented = error { throw error }
                        state.notes.append("project \(ref.lastPathComponent) not read: \(error)")
                    }
                } else if fm.fileExists(atPath: ref.appendingPathComponent("Package.swift").path) {
                    state.packages.append(ProjectModel.PackageReference(url: nil, path: ref, requirement: .local))
                }
            }
            state.schemes += SchemeReader.schemes(in: url, notes: &state.notes).map { ($0, nil) }
        case "xcodeproj":
            kind = .xcodeproj(url)
            root = url.deletingLastPathComponent()
            try state.readProject(url)
        default:
            var isDir: ObjCBool = false
            fm.fileExists(atPath: url.path, isDirectory: &isDir)
            let manifest = isDir.boolValue ? url.appendingPathComponent("Package.swift") : url
            guard manifest.lastPathComponent == "Package.swift", fm.fileExists(atPath: manifest.path) else {
                throw XcblameError.projectNotFound("\(url.path) is not an .xcworkspace, .xcodeproj or Package.swift")
            }
            kind = .package(manifest)
            root = manifest.deletingLastPathComponent()
            state.packages.append(ProjectModel.PackageReference(url: nil, path: root, requirement: .local))
            state.schemes += SchemeReader.schemes(in: root.appendingPathComponent(".swiftpm/xcode"), notes: &state.notes)
                .map { ($0, nil) }
        }

        state.resolvePackages()
        state.noteXCConfigIssues()
        for index in state.projects.indices {
            state.projects[index].defaultConfiguration = state.defaultConfiguration(projectIndex: index)
        }
        if let scheme, !state.schemes.contains(where: { $0.facts.scheme.name == scheme }) {
            state.notes.append("scheme \(scheme) not found among the shared and user schemes")
        }

        let format: ProjectModel.Format
        switch kind {
        case .package: format = .package
        default:
            guard let first = state.projects.first else {
                throw XcblameError.projectUnreadable("\(url.path) references no readable project")
            }
            format = .pbxproj(objectVersion: first.objectVersion ?? 0)
        }

        var managers: [ProjectModel.DependencyManager] = []
        let podfile = root.appendingPathComponent("Podfile")
        if fm.fileExists(atPath: podfile.path) {
            let lock = root.appendingPathComponent("Podfile.lock")
            let lockfile = fm.fileExists(atPath: lock.path) ? lock : nil
            managers.append(.cocoapods(podfile: podfile, lockfile: lockfile,
                                       podCount: lockfile.flatMap { ManifestReaders.podCount(lockfile: $0) }))
        } else if state.podsProject != nil || state.hasCocoaPodsPhases {
            state.notes.append("CocoaPods in use (Pods project or [CP] phases) but no Podfile next to the container")
        }
        if state.hasCocoaPodsPhases || fm.fileExists(atPath: root.appendingPathComponent("Pods").path) {
            state.notes.append("CocoaPods-managed: [CP] phases and Pods/ xcconfigs are regenerated by pod install")
        }
        let cartfile = root.appendingPathComponent("Cartfile")
        if fm.fileExists(atPath: cartfile.path) { managers.append(.carthage(cartfile: cartfile)) }
        if !state.packages.isEmpty { managers.append(.spm) }

        var seen: Set<String> = []
        let notes = state.notes.filter { seen.insert($0).inserted }
        return ProjectModel(root: root, container: kind, format: format, projects: state.projects,
                            schemes: state.schemes.map(\.facts.scheme), packages: state.packages,
                            dependencyManagers: managers,
                            generator: GeneratorDetector.detect(root: root, isPackage: format == .package), notes: notes)
    }

    private struct State {
        let scheme: String?
        let cache = XCConfigCache()
        var projects: [ProjectModel.Project] = []
        var schemes: [(facts: SchemeReader.Facts, projectIndex: Int?)] = []
        var packages: [ProjectModel.PackageReference] = []
        var unbound: [(product: String, target: String)] = []
        var hasCocoaPodsPhases = false
        var podsProject: URL?
        var notes: [String] = []

        init(scheme: String?) { self.scheme = scheme }

        mutating func readProject(_ url: URL) throws {
            let result = try PBXProjReader.read(xcodeproj: url, xcconfigCache: cache)
            let index = projects.count
            projects.append(result.project)
            packages += result.packages
            unbound += result.unboundProducts
            hasCocoaPodsPhases = hasCocoaPodsPhases || result.hasCocoaPodsPhases
            notes += result.notes
            schemes += SchemeReader.schemes(in: url, notes: &notes).map { ($0, index) }
        }

        /// Deduplicates by URL or path, reads local manifests, binds product dependencies without a `package` key.
        mutating func resolvePackages() {
            var merged: [ProjectModel.PackageReference] = []
            var index: [String: Int] = [:]
            for package in packages {
                let key = Self.key(package)
                if let i = index[key] {
                    for product in package.products where !merged[i].products.contains(product) {
                        merged[i].products.append(product)
                    }
                    for consumer in package.consumers where !merged[i].consumers.contains(consumer) {
                        merged[i].consumers.append(consumer)
                    }
                } else {
                    index[key] = merged.count
                    merged.append(package)
                }
            }
            var localProducts: [Int: Set<String>] = [:]
            for i in merged.indices {
                guard let dir = merged[i].path else { continue }
                let manifest = dir.appendingPathComponent("Package.swift")
                guard FileManager.default.fileExists(atPath: manifest.path) else {
                    notes.append("local package \(dir.path) has no Package.swift")
                    continue
                }
                do {
                    let parsed = try ManifestReaders.package(manifest: manifest)
                    merged[i].manifest = parsed.manifest
                    notes += parsed.notes
                    localProducts[i] = Set(parsed.products).union(parsed.manifest.targets.map(\.name))
                } catch {
                    notes.append("local package manifest not read: \(error)")
                }
            }
            for (product, target) in unbound {
                guard let i = localProducts.keys.sorted().first(where: { localProducts[$0]!.contains(product) }) else {
                    notes.append("target \(target) links package product \(product), which no package reference provides")
                    continue
                }
                if !merged[i].products.contains(product) { merged[i].products.append(product) }
                if !merged[i].consumers.contains(target) { merged[i].consumers.append(target) }
            }
            packages = merged
        }

        /// Notes for every xcconfig reachable from a configuration: missing `#include`s (which break the build),
        /// unresolvable include paths, line continuations.
        mutating func noteXCConfigIssues() {
            var queue: [URL] = []
            for project in projects {
                queue += project.projectXCConfig.keys.sorted().compactMap { project.projectXCConfig[$0] }
                for target in project.targets {
                    queue += target.xcconfig.keys.sorted().compactMap { target.xcconfig[$0] }
                }
            }
            var visited: Set<URL> = []
            while let url = queue.first {
                queue.removeFirst()
                guard visited.insert(url).inserted, FileManager.default.fileExists(atPath: url.path),
                      let parsed = try? XCConfigReader.parse(url: url) else { continue }
                for event in parsed.events {
                    guard case let .include(target, optional) = event else { continue }
                    if FileManager.default.fileExists(atPath: target.path) {
                        queue.append(target)
                    } else if !optional {
                        notes.append("xcconfig \(url.path): #include \(target.path) does not exist (the build fails)")
                    }
                }
                for path in parsed.unresolvedIncludes {
                    notes.append("xcconfig \(url.path): #include \"\(path)\" left as written (build-setting "
                        + "references in include paths are not expanded)")
                }
                if parsed.hasContinuation {
                    notes.append("xcconfig \(url.path): line continuations (trailing \\) are not supported")
                }
            }
        }

        /// The scheme's `LaunchAction` configuration (the `scheme` argument, else this project's first shared then
        /// user scheme), else `Debug` when present, else the project list's `defaultConfigurationName`, else the
        /// first configuration.
        func defaultConfiguration(projectIndex: Int) -> String? {
            let project = projects[projectIndex]
            let candidates: [SchemeReader.Facts]
            if let scheme {
                let named = schemes.filter { $0.facts.scheme.name == scheme }
                candidates = (named.filter { $0.projectIndex == projectIndex } + named.filter { $0.projectIndex == nil }
                    + named).map(\.facts)
            } else {
                candidates = schemes.filter { $0.projectIndex == projectIndex }.map(\.facts)
            }
            if let launch = candidates.first?.launchConfiguration, project.configurations.contains(launch) {
                return launch
            }
            if project.configurations.contains("Debug") { return "Debug" }
            return project.defaultConfiguration ?? project.configurations.first
        }

        private static func key(_ package: ProjectModel.PackageReference) -> String {
            if let path = package.path { return "path:" + path.standardizedFileURL.path }
            var url = (package.url ?? "").lowercased()
            while url.hasSuffix("/") { url.removeLast() }
            if url.hasSuffix(".git") { url.removeLast(4) }
            return "url:" + url
        }
    }
}
