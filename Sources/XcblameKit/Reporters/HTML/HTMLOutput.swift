import Foundation

/// Writes an HTML report atomically to `explicit` (`-o`) or `reportsDir/<yyyyMMdd-HHmmss>-<kind>.html`, then opens it
/// when asked and not on CI (DESIGN §8.2.5). Returns the written file. The caller prints the summary line and the
/// `open "<path>"` hint; this only warns on stderr when opening fails.
public enum HTMLOutput {
    public static func write(_ data: Data, to explicit: String?, kind: String?, reportsDir: URL, open: Bool,
                             browser: String?, isCI: Bool) throws -> URL {
        let url = explicit.map { URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath) }
            ?? reportsDir.appendingPathComponent(defaultName(kind: kind, date: Date()))
        // Atomic writes need a temp file next to the target, which devices such as /dev/null do not allow.
        let type = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType
        if type == nil {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        if explicit == nil { ensureStateIgnore(in: reportsDir.deletingLastPathComponent()) }
        try data.write(to: url, options: type == nil || type == .typeRegular ? .atomic : [])
        if open, !isCI { openReport(url, browser: browser) }
        return url
    }

    /// `<yyyyMMdd-HHmmss>-<kind>.html` in local time; `report` when the build kind is unknown.
    static func defaultName(kind: String?, date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let safe = (kind ?? "report").map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "-" }
        return "\(formatter.string(from: date))-\(safe.isEmpty ? "report" : String(safe)).html"
    }

    /// `/usr/bin/open [-a browser] <file>`; when the browser fails, retries with the default browser and warns.
    static func openReport(_ url: URL, browser: String?) {
        if let browser {
            if runOpen(["-a", browser, url.path]) { return }
            warn("warning: could not open the report with \(browser); using the default browser")
        }
        if !runOpen([url.path]) { warn("warning: could not open \(url.path); open it by hand") }
    }

    private static func runOpen(_ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    private static func warn(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}
