import CryptoKit
import Foundation

/// xcodebuild results on disk: `cacheDir/<sha256(container, configuration, scheme, xcodebuild version, xcblame
/// version, XCODE_XCCONFIG_FILE)>.json`, valid
/// while the mtimes of every input (project files, xcconfigs and their includes, schemes, manifests, lockfiles) are
/// unchanged. Offline results are never cached.
enum SettingsCache {
    struct Entry: Codable {
        /// Input path to mtime (seconds since 1970), -1 for a file that did not exist.
        var inputs: [String: Double]
        var settings: EffectiveSettings
    }

    static func sha256(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func file(cacheDir: URL, project: ProjectModel, configuration: String, scheme: String?,
                     xcodeVersion: String) -> URL {
        // The xcblame version (an upgrade may change the oracle) and XCODE_XCCONFIG_FILE (it changes the values).
        let key = [project.container.url.standardizedFileURL.path, configuration, scheme ?? "", xcodeVersion,
                   XcblameVersion.current, ProcessInfo.processInfo.environment["XCODE_XCCONFIG_FILE"] ?? ""]
            .joined(separator: "\n")
        return cacheDir.appendingPathComponent(sha256(key) + ".json")
    }

    /// The files whose change invalidates an entry.
    static func inputs(project: ProjectModel) -> [URL] {
        var urls: [URL] = []
        var resolver = ProvenanceResolver(project: project)
        func xcconfig(_ url: URL) {
            let chain = resolver.chain(url)
            urls += chain.files + chain.missing.map(\.url)
            if chain.files.isEmpty, chain.missing.isEmpty { urls.append(url) }
        }
        for proj in project.projects {
            urls.append(proj.path.appendingPathComponent("project.pbxproj"))
            urls.append(proj.path.appendingPathComponent("project.xcworkspace/xcshareddata/swiftpm/Package.resolved"))
            proj.projectXCConfig.values.forEach(xcconfig)
            proj.targets.flatMap(\.xcconfig.values).forEach(xcconfig)
        }
        urls += project.schemes.map(\.path)
        for package in project.packages {
            guard let path = package.path else { continue }
            urls.append(path.lastPathComponent == "Package.swift" ? path : path.appendingPathComponent("Package.swift"))
        }
        let container = project.container.url
        switch project.container {
        case .xcworkspace:
            urls.append(container.appendingPathComponent("contents.xcworkspacedata"))
            urls.append(container.appendingPathComponent("xcshareddata/swiftpm/Package.resolved"))
        case .package:
            urls.append(container)
            urls.append(container.deletingLastPathComponent().appendingPathComponent("Package.resolved"))
        case .xcodeproj:
            break
        }
        urls.append(project.root.appendingPathComponent("Podfile.lock"))
        return urls
    }

    static func snapshot(_ urls: [URL]) -> [String: Double] {
        var out: [String: Double] = [:]
        for url in urls {
            let path = url.standardizedFileURL.path
            let date = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
            out[path] = date?.timeIntervalSince1970 ?? -1
        }
        return out
    }

    static func load(_ file: URL, project: ProjectModel) -> EffectiveSettings? {
        guard let data = FileManager.default.contents(atPath: file.path),
              let entry = try? JSONDecoder().decode(Entry.self, from: data),
              entry.inputs == snapshot(inputs(project: project)) else { return nil }
        return entry.settings
    }

    static func store(_ settings: EffectiveSettings, file: URL, inputs: [String: Double]) {
        guard settings.source == .xcodebuild else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(Entry(inputs: inputs, settings: settings)) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }
}

extension SettingsOracle {
    /// Drops every cached xcodebuild result in `cacheDir` (the scratch workspaces and DerivedData stay).
    public static func invalidateCache(cacheDir: URL) {
        let fm = FileManager.default
        for name in (try? fm.contentsOfDirectory(atPath: cacheDir.path)) ?? [] where name.hasSuffix(".json") {
            try? fm.removeItem(at: cacheDir.appendingPathComponent(name))
        }
    }
}
