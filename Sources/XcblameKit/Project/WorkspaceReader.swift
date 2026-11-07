import Foundation

/// Reads `contents.xcworkspacedata`: the file references of a workspace, resolved to absolute URLs. Read-only.
enum WorkspaceReader {
    static func references(of workspace: URL) throws -> [URL] {
        let data = workspace.appendingPathComponent("contents.xcworkspacedata")
        guard FileManager.default.fileExists(atPath: data.path) else {
            throw XcblameError.projectUnreadable("\(workspace.path) has no contents.xcworkspacedata")
        }
        guard let doc = try? XMLDocument(contentsOf: data, options: []), let root = doc.rootElement() else {
            throw XcblameError.projectUnreadable("\(data.path) is not readable XML")
        }
        let containerDir = workspace.deletingLastPathComponent()
        var out: [URL] = []
        walk(root, base: containerDir, containerDir: containerDir, workspace: workspace, into: &out)
        return out
    }

    private static func walk(_ element: XMLElement, base: URL, containerDir: URL, workspace: URL, into out: inout [URL]) {
        for child in element.children ?? [] {
            guard let child = child as? XMLElement else { continue }
            let location = child.attribute(forName: "location")?.stringValue ?? ""
            let resolved = resolve(location, base: base, containerDir: containerDir, workspace: workspace)
            switch child.name {
            case "FileRef":
                if let resolved { out.append(resolved.standardizedFileURL) }
            case "Group":
                walk(child, base: resolved ?? base, containerDir: containerDir, workspace: workspace, into: &out)
            default:
                continue
            }
        }
    }

    /// `group:` is relative to the enclosing group, `container:` to the workspace's folder, `absolute:` is absolute,
    /// `self:` is the project that owns an embedded `project.xcworkspace`; anything else (`developer:`) is skipped.
    private static func resolve(_ location: String, base: URL, containerDir: URL, workspace: URL) -> URL? {
        guard let colon = location.firstIndex(of: ":") else { return nil }
        let kind = location[..<colon]
        let path = String(location[location.index(after: colon)...])
        func join(_ dir: URL) -> URL {
            if path.isEmpty { return dir }
            return path.hasPrefix("/") ? URL(fileURLWithPath: path) : dir.appendingPathComponent(path)
        }
        switch kind {
        case "group": return join(base)
        case "container": return join(containerDir)
        case "absolute": return URL(fileURLWithPath: path)
        case "self":
            let owner = workspace.deletingLastPathComponent()
            return owner.pathExtension == "xcodeproj" ? owner : nil
        default: return nil
        }
    }
}
