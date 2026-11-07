import Foundation

/// Owner class per target (DESIGN §6.4): `app`, `localPackage`, `remotePackage`, `pods`, `macroPlugin`,
/// `systemModules`, `buildSystem`, `unknown`. From paths only: the target's own path, then the source files its
/// compile tasks name; a project without paths inherits its siblings' class.
enum Owner {
    static func classify(model: BuildModel) -> [Int: String] {
        let macroPlugins = macroPluginNames(model)
        let workspaceRoots = Set(model.targets.compactMap { target -> String? in
            guard let path = target.path, path.hasSuffix(".xcodeproj") || path.hasSuffix(".xcworkspace") else {
                return nil
            }
            return (path as NSString).deletingLastPathComponent
        })
        var sources: [Int: [String]] = [:]
        for task in model.tasks where task.kind == .swiftCompile || task.kind == .clangCompile {
            guard let target = task.targetId, (sources[target]?.count ?? 0) < 8,
                  let file = FileAttribution.files(of: task).first else { continue }
            sources[target, default: []].append(file)
        }
        var owners: [Int: String] = [:]
        for target in model.targets {
            owners[target.id] = classify(target, sources: sources[target.id] ?? [], workspaceRoots: workspaceRoots,
                                         macroPlugins: macroPlugins)
        }
        // A target with no path evidence takes the class its project's other targets share.
        var byProject: [String: Set<String>] = [:]
        for target in model.targets where owners[target.id] != "unknown" {
            if let project = target.project { byProject[project, default: []].insert(owners[target.id]!) }
        }
        for target in model.targets where owners[target.id] == "unknown" {
            if let project = target.project, let classes = byProject[project], classes.count == 1 {
                owners[target.id] = classes.first
            }
        }
        return owners
    }

    static func classify(_ target: Target, sources: [String], workspaceRoots: Set<String>,
                         macroPlugins: Set<String>) -> String {
        if target.isBucket {
            return target.name == Target.explicitModulesBucket ? "systemModules" : "buildSystem"
        }
        if macroPlugins.contains(target.name) { return "macroPlugin" }
        let paths = [target.path].compactMap { $0 } + sources
        if paths.contains(where: { $0.contains("/checkouts/") }) { return "remotePackage" }
        if paths.contains(where: { $0.contains("/Pods/") }) { return "pods" }
        if let path = target.path {
            if path.hasSuffix(".xcodeproj") || path.hasSuffix(".xcworkspace") { return "app" }
            let inside = workspaceRoots.isEmpty || workspaceRoots.contains { path.hasPrefix($0 + "/") }
            if path.hasSuffix("Package.swift") || target.isPackage { return inside ? "localPackage" : "unknown" }
        }
        // Sources outside checkouts and Pods: the project's own code.
        if !sources.isEmpty { return target.isPackage ? "localPackage" : "app" }
        return "unknown"
    }

    /// Targets named by `-load-plugin-executable <path>/<Name>#<Module>` in a Swift planning command.
    static func macroPluginNames(_ model: BuildModel) -> Set<String> {
        var names = Set<String>()
        for task in model.tasks where task.ruleName == "SwiftDriver" {
            guard let text = task.commandDetails, text.contains("-load-plugin-executable") else { continue }
            let tokens = text.split(whereSeparator: { $0 == " " || $0.isNewline })
            for (index, token) in tokens.enumerated() where token == "-load-plugin-executable"
                && index + 1 < tokens.count {
                let executable = tokens[index + 1].split(separator: "#").first.map(String.init) ?? ""
                names.insert((executable as NSString).lastPathComponent)
            }
        }
        return names
    }
}
