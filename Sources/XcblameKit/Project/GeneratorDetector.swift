import Foundation

/// Finds the source a project is generated from, next to the container (docs/SCHEMA-v0.3.md `Generator`).
enum GeneratorDetector {
    /// XcodeGen (`project.yml` / `project.json`) before Tuist (`Project.swift`, `Workspace.swift`, `Tuist.swift`,
    /// `Tuist/Config.swift`, or a bare `Tuist/` folder); nil for a `Package.swift` container or when none is present.
    static func detect(root: URL, isPackage: Bool) -> ProjectModel.Generator? {
        guard !isPackage else { return nil }
        let fm = FileManager.default
        func file(_ name: String) -> URL? {
            let url = root.appendingPathComponent(name)
            var isDir: ObjCBool = false
            return fm.fileExists(atPath: url.path, isDirectory: &isDir) && !isDir.boolValue ? url.standardizedFileURL : nil
        }
        if let spec = file("project.yml") ?? file("project.json") { return .xcodegen(spec: spec) }
        if let manifest = file("Project.swift") ?? file("Workspace.swift") ?? file("Tuist.swift")
            ?? file("Tuist/Config.swift") {
            return .tuist(manifest: manifest)
        }
        var isDir: ObjCBool = false
        let tuistDir = root.appendingPathComponent("Tuist")
        if fm.fileExists(atPath: tuistDir.path, isDirectory: &isDir), isDir.boolValue {
            return .tuist(manifest: tuistDir.standardizedFileURL)
        }
        return nil
    }
}
