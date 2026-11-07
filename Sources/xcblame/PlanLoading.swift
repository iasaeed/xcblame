import Foundation
import XcblameKit

/// The analysis a plan is made from: a history entry (`id`), a saved report JSON (`path`), or none (static findings
/// only).
struct PlanAnalysis {
    var document: ReportDocument?
    var id: String?
    var path: String?
}

/// Plan building shared by `fix` and `verify` (docs/SCHEMA-v0.6.md "`xcblame fix`" plan inputs, "`xcblame verify`"
/// `--plan` default): a doctor pass (as `xcblame doctor`, same oracle) plus the analysis, through `FixPlanner`.
enum PlanLoading {
    /// `given` (a `.xcodeproj`/`.xcworkspace`/folder, must exist), or the container found in the current directory.
    static func locateContainer(_ given: String?) throws -> URL {
        let url = URL(fileURLWithPath: NSString(string: given ?? ".").expandingTildeInPath).standardizedFileURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XcblameError.projectNotFound("\(url.path) does not exist")
        }
        guard let container = ProjectLocator.find(startingAt: url) else {
            throw XcblameError.projectNotFound("no .xcworkspace, .xcodeproj or Package.swift in \(url.path) "
                + "(pass --project or --workspace)")
        }
        return container
    }

    /// The analysis `from` names (a report JSON file or a history entry id), else the newest history entry that is
    /// not a `build --deep` one, else none.
    static func analysis(from: String?, xcblameDir: URL) throws -> PlanAnalysis {
        let history = xcblameDir.appendingPathComponent("history")
        if let from {
            let url = URL(fileURLWithPath: NSString(string: from).expandingTildeInPath).standardizedFileURL
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue {
                do {
                    return PlanAnalysis(document: try JSONReporter.decoder().decode(ReportDocument.self, from: Data(contentsOf: url)),
                                        id: nil, path: url.path)
                } catch {
                    throw XcblameError.readerFailure("\(url.path) is not an xcblame report JSON (\(error))")
                }
            }
            do {
                let shown = try History.show(id: from, directory: history)
                return PlanAnalysis(document: shown.document, id: shown.item.id, path: nil)
            } catch {
                throw XcblameError.logNotFound("--from \(from): no such report file or history entry (\(error))")
            }
        }
        for item in History.list(directory: history, details: false) {
            guard let shown = try? History.show(id: item.id, directory: history), shown.document.deep == nil else { continue }
            return PlanAnalysis(document: shown.document, id: shown.item.id, path: nil)
        }
        return PlanAnalysis()
    }

    /// A doctor pass over `configurations` (empty: every configuration of the project) plus `analysis`, through
    /// `FixPlanner` (a stored plan with the same id keeps its verify states). Not stored: the caller saves it.
    static func makePlan(model: ProjectModel, container: URL, analysis: PlanAnalysis, configurations: [String],
                         rules: [String]?, offline: Bool, isCI: Bool, xcblameDir dir: URL, now: Date) throws -> FixPlanDocument {
        let evaluated = configurations.isEmpty ? model.configurationNames : configurations
        let settings = SettingsOracle.effectiveAll(project: model, configurations: evaluated, scheme: nil, offline: offline,
                                                   cacheDir: dir.appendingPathComponent("cache/settings"),
                                                   totalTimeout: SettingsOracle.doctorTotalTimeout)
        let env = EnvSnapshot.capture()
        let xcode = env.xcodebuildVersion?.split(whereSeparator: \.isNewline).first
            .map { $0.replacingOccurrences(of: "Xcode ", with: "") }
        let context = RuleContext(project: model, settings: settings,
                                  provenance: RuleContext.oracleProvenance(model, settings: settings),
                                  env: env, xcode: xcode, isCI: isCI, offline: offline)
        let result = RuleEngine.run(context, rules: rules)
        let doctor = ReportDocument.makeDoctor(project: model, settings: settings, result: result, configurations: evaluated,
                                               environment: env, xcode: xcode, generatedAt: now, durationSeconds: nil,
                                               offline: offline, failOn: nil)
        var planner = FixPlanner(analysisPath: analysis.path, isDirty: HookInstaller.gitDirty)
        if !offline, model.container != .package(model.container.url) {
            planner.cliOracle = cliOracle(model: model, xcblameDir: dir)
        }
        var plan = try planner.plan(FixPlanRequest(doctor: doctor, analysis: analysis.document, analysisId: analysis.id,
                                                   context: context, rules: rules, xcblameDir: dir, generatedAt: now))
        plan.notes += result.notes
        return plan
    }

    /// The `-xcconfig` oracle for the cli scope rows: the scratch-workspace oracle (generated scheme, `-derivedDataPath`
    /// in the oracle cache, so nothing lands under `~/Library/Developer`; review D/C) with the lines in a scratch
    /// xcconfig under `<xcblame-dir>/tmp`.
    private static func cliOracle(model: ProjectModel, xcblameDir: URL) -> FixPlanner.CLIOracle {
        { configuration, lines in
            let url = xcblameDir.appendingPathComponent("tmp/fix-oracle-\(configuration).xcconfig")
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard (try? Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url, options: .atomic)) != nil else {
                return nil
            }
            defer { try? FileManager.default.removeItem(at: url) }
            return SettingsOracle.effectiveInScratch(project: model, configuration: configuration, xcconfig: url).settings
        }
    }
}
