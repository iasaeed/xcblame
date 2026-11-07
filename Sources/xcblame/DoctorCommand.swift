import ArgumentParser
import Foundation
import XcblameKit

/// `--fail-on`: the lowest finding severity that makes `doctor` exit 4.
enum FailOnSeverity: String, ExpressibleByArgument, CaseIterable {
    case none, low, medium, high
}

/// Comma-separated list option values (`--rules SET-001,PHASE-001`).
func commaList(_ text: String?) -> [String]? {
    guard let text else { return nil }
    let items = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    return items.isEmpty ? nil : items
}

/// `--category set,phase` (case-insensitive) as catalog categories.
func parseCategories(_ text: String?) throws -> [RuleSpec.Category]? {
    try commaList(text)?.map { name in
        guard let category = RuleSpec.Category(rawValue: name.lowercased()) else {
            let known = RuleSpec.Category.allCases.map(\.rawValue).joined(separator: ", ")
            throw ValidationError("unknown category \(name) (known: \(known))")
        }
        return category
    }
}

struct DoctorCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "doctor",
        abstract: "Static audit of a project, no build: settings, scripts, dependencies, schemes and machine.")

    @Argument(help: "A project folder, .xcodeproj, .xcworkspace or Package.swift (default: current directory).",
              completion: .file())
    var path: String?
    @Option(help: "The .xcodeproj to audit.", completion: .file(extensions: ["xcodeproj"]))
    var project: String?
    @Option(help: "The .xcworkspace to audit.", completion: .file(extensions: ["xcworkspace"]))
    var workspace: String?
    @Option(help: "Scheme passed to xcodebuild -showBuildSettings (default: none, all targets).")
    var scheme: String?
    @Option(name: .customLong("configuration"),
            help: "Configuration to evaluate; repeat for several (default: every configuration of the project).")
    var configurations: [String] = []
    @Flag(help: "Do not run xcodebuild: resolve settings from the project files only (confidence drops one step).")
    var offline = false
    @Option(help: "Only these rule ids, comma-separated.")
    var rules: String?
    @Option(help: "Only these categories, comma-separated: set, src, graph, phase, dep, env, ci, dyn.")
    var category: String?
    @Option(name: .customLong("fail-on"),
            help: "Exit 4 when a finding of this severity or higher is present: none, low, medium, high.")
    var failOn: FailOnSeverity = .none
    @Option(name: .customLong("xcblame-dir"), help: "xcblame state folder (settings cache, reports).",
            completion: .directory)
    var xcblameDir: String = ".xcblame"
    @OptionGroup var global: GlobalOptions

    func validate() throws {
        if [path, project, workspace].compactMap({ $0 }).count > 1 {
            throw ValidationError("give one of <path>, --project or --workspace")
        }
        _ = try parseCategories(category)
        // A typo in a CI gate (`--rules SET-01 --fail-on medium`) must not pass silently.
        if let ids = commaList(rules), !ids.contains(where: { RuleCatalog.spec($0) != nil }) {
            throw ValidationError("no known rule among --rules \(ids.joined(separator: ",")) (xcblame rules list shows the ids)")
        }
    }

    func run() throws {
        let start = Date()
        let container = try locateContainer()
        let model = try ProjectModel.load(container: container, scheme: scheme)
        let evaluated = configurations.isEmpty ? model.configurationNames : configurations
        // One concurrent batch for every configuration (the 200-target budget needs it); never throws: a failed
        // configuration falls back to the offline resolver with a note.
        let settings = SettingsOracle.effectiveAll(project: model, configurations: evaluated, scheme: scheme,
                                                   offline: offline, cacheDir: stateURL.appendingPathComponent("cache/settings"),
                                                   totalTimeout: SettingsOracle.doctorTotalTimeout)
        noteState(model, oracleRan: settings.values.contains { $0.source == .xcodebuild && !$0.notes.contains("cache hit") })
        let env = EnvSnapshot.capture()
        let xcode = env.xcodebuildVersion?.split(whereSeparator: \.isNewline).first
            .map { $0.replacingOccurrences(of: "Xcode ", with: "") }
        let context = RuleContext(project: model, settings: settings,
                                  provenance: RuleContext.oracleProvenance(model, settings: settings),
                                  env: env, xcode: xcode, isCI: global.isCI, offline: offline)
        let result = RuleEngine.run(context, rules: commaList(rules), categories: try parseCategories(category))
        var document = ReportDocument.makeDoctor(
            project: model, settings: settings, result: result, configurations: evaluated, environment: env,
            xcode: xcode, generatedAt: Date(), durationSeconds: Date().timeIntervalSince(start), offline: offline,
            failOn: failOn == .none ? nil : failOn.rawValue)
        document.markVerified(FixPlanner.verifyLabels(xcblameDir: stateURL))
        document = try ReportPipeline.prepareForOutput(document, redact: global.resolvedRedact)
        try render(document)
        if document.doctor?.failed == true { throw ArgumentParser.ExitCode(XcblameExit.failOnHit.rawValue) }
    }

    // MARK: - Steps

    /// The state folder is git-ignored as soon as it exists; old oracle entries go; `--verbose` prints the cache size.
    /// The 5 GB cap walks every entry, so it runs only after the oracle wrote something (not on cache hits).
    private func noteState(_ model: ProjectModel, oracleRan: Bool) {
        if FileManager.default.fileExists(atPath: stateURL.path) { ensureStateIgnore(in: stateURL) }
        let home = OracleCache.home()
        OracleCache.prune(home: home, olderThanDays: OracleCache.keepDays, maxBytes: oracleRan ? OracleCache.maxBytes : nil)
        if global.verbose {
            let dir = OracleCache.directory(for: model.container.url, home: home)
            let entries = OracleCache.entries(home: home)
            let total = entries.reduce(Int64(0)) { $0 + OracleCache.size(of: $1.url) }
            writeStderr("verbose: settings-oracle cache \(dir.path): "
                + String(format: "%.1f MB", Double(OracleCache.size(of: dir)) / 1_048_576)
                + "; \(entries.count) entries, " + String(format: "%.1f MB", Double(total) / 1_048_576) + " total "
                + "(cap \(OracleCache.maxBytes >> 30) GB; xcblame history prune --oracle-cache removes it)")
        }
    }

    private var stateURL: URL {
        URL(fileURLWithPath: NSString(string: xcblameDir).expandingTildeInPath).standardizedFileURL
    }

    /// `--project` / `--workspace` / `<path>` as given (must exist), or the container found in the folder.
    private func locateContainer() throws -> URL {
        let given = project ?? workspace ?? path ?? "."
        let url = URL(fileURLWithPath: NSString(string: given).expandingTildeInPath).standardizedFileURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XcblameError.projectNotFound("\(url.path) does not exist")
        }
        guard let container = ProjectLocator.find(startingAt: url) else {
            throw XcblameError.projectNotFound("no .xcworkspace, .xcodeproj or Package.swift in \(url.path) "
                + "(pass a project folder, --project or --workspace)")
        }
        return container
    }

    private func render(_ document: ReportDocument) throws {
        let format = global.resolvedFormat
        if global.open, format != .html, !global.quiet { writeStderr("note: --open applies only to --format html") }
        switch format {
        case .text: try emit(Data(TextReporter.renderDoctor(document, colors: global.useColors).utf8),
                             document: document, format: format)
        case .json: try emit(try JSONReporter.render(document), document: document, format: format)
        case .markdown, .github, .junit, .agent:
            try emit(try renderTextFormat(document, format: format, maxReportBytes: nil, xcblameDir: stateURL),
                     document: document, format: format)
        case .html:
            let rendered = try HTMLReporter.renderReport(document, taskIndex: nil, options: HTMLReporter.Options(
                redact: global.resolvedRedact, title: "xcblame doctor"))
            if global.open, global.isCI, !global.quiet { writeStderr("note: --open ignored because CI=true") }
            let open = global.open && !global.isCI
            let url = try HTMLOutput.write(rendered.data, to: global.output, kind: "doctor",
                                           reportsDir: stateURL.appendingPathComponent("reports"), open: open,
                                           browser: global.browser, isCI: global.isCI)
            if !global.quiet {
                print("wrote \(url.path) (html, \(rendered.data.count) bytes) · \(summary(document))")
                if !open { print("open \"\(url.path)\"") }
            }
        }
    }

    private func summary(_ document: ReportDocument) -> String {
        "\(document.findings.count) finding(s), \(document.doctor?.rulesEvaluated ?? 0) rules evaluated · settings: "
            + (document.project?.settingsSource ?? "mixed or none (see project notes)")
    }

    private func emit(_ rendered: Data, document: ReportDocument, format: OutputFormat) throws {
        guard let output = global.output else {
            FileHandle.standardOutput.write(rendered)
            return
        }
        let url = URL(fileURLWithPath: NSString(string: output).expandingTildeInPath)
        let type = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType
        try rendered.write(to: url, options: type == nil || type == .typeRegular ? .atomic : [])
        if !global.quiet { print("wrote \(url.path) (\(format.rawValue), \(rendered.count) bytes) · \(summary(document))") }
    }
}
