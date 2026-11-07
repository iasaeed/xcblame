import Foundation

/// Reads `.xcscheme` files (XML). Read-only.
enum SchemeReader {
    struct Facts {
        var scheme: ProjectModel.Scheme
        /// `LaunchAction buildConfiguration` (what Run and `xcodebuild -scheme … build` use).
        var launchConfiguration: String?
        /// `BlueprintName`s of the build action entries.
        var buildTargets: [String]
    }

    /// Shared (`xcshareddata/xcschemes`) then user (`xcuserdata/*/xcschemes`) schemes under `bundle` (an
    /// `.xcodeproj`, `.xcworkspace` or `.swiftpm/xcode`), each group sorted by file name. Unreadable files become notes.
    static func schemes(in bundle: URL, notes: inout [String]) -> [Facts] {
        let fm = FileManager.default
        var out: [Facts] = []
        let shared = bundle.appendingPathComponent("xcshareddata/xcschemes")
        for file in schemeFiles(in: shared) {
            if let facts = read(file, isShared: true, notes: &notes) { out.append(facts) }
        }
        let userData = bundle.appendingPathComponent("xcuserdata")
        let users = ((try? fm.contentsOfDirectory(atPath: userData.path)) ?? []).filter { $0.hasSuffix(".xcuserdatad") }.sorted()
        for user in users {
            for file in schemeFiles(in: userData.appendingPathComponent(user).appendingPathComponent("xcschemes")) {
                if let facts = read(file, isShared: false, notes: &notes) { out.append(facts) }
            }
        }
        return out
    }

    static func read(_ url: URL, isShared: Bool, notes: inout [String]) -> Facts? {
        guard let doc = try? XMLDocument(contentsOf: url, options: []), let root = doc.rootElement(),
              root.name == "Scheme" else {
            notes.append("scheme \(url.lastPathComponent) is not readable XML; skipped")
            return nil
        }
        let build = root.elements(forName: "BuildAction").first
        let launch = root.elements(forName: "LaunchAction").first
        let entries = build?.elements(forName: "BuildActionEntries").first?.elements(forName: "BuildActionEntry") ?? []
        let targets = entries.compactMap {
            $0.elements(forName: "BuildableReference").first?.attribute(forName: "BlueprintName")?.stringValue
        }
        let scheme = ProjectModel.Scheme(
            name: url.deletingPathExtension().lastPathComponent, path: url.standardizedFileURL,
            parallelizeBuildables: bool(build?.attribute(forName: "parallelizeBuildables")?.stringValue),
            buildImplicitDependencies: bool(build?.attribute(forName: "buildImplicitDependencies")?.stringValue),
            isShared: isShared)
        let configuration = launch?.attribute(forName: "buildConfiguration")?.stringValue
        return Facts(scheme: scheme, launchConfiguration: configuration?.isEmpty == false ? configuration : nil,
                     buildTargets: targets)
    }

    private static func schemeFiles(in dir: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0.hasSuffix(".xcscheme") }.sorted().map { dir.appendingPathComponent($0) }
    }

    private static func bool(_ s: String?) -> Bool? {
        switch s?.uppercased() {
        case "YES", "TRUE", "1": return true
        case "NO", "FALSE", "0": return false
        default: return nil
        }
    }
}
