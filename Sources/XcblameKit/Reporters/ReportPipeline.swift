import Foundation

/// Model -> Analysis -> Validation -> ReportDocument, in one place so the CLI, `selftest` and the tests build the
/// report the same way.
public enum ReportPipeline {
    public struct Options: Sendable {
        public var topN: Int
        public var budgetBytes: Int
        public var generatedAt: Date
        public var inputPath: String?
        /// Environment snapshot to include in the report; nil leaves `environment` null.
        public var environment: EnvSnapshot?
        /// Build description matched to the log (DESIGN §5.11); nil means the critical path falls back to inference.
        public var buildDescription: BuildDescription?
        /// Physical cores of the building machine, for the serial-stretch threshold (§6.3).
        public var physicalCores: Int?
        /// xcodebuild process wall time, known only to `xcblame build`.
        public var processWall: Double?
        /// False for html: V13 is then measured on the rendered page after the budget pass (`HTMLReporter`), not on
        /// the untruncated JSON, and size never fails the command (§8.2.3).
        public var checksSize: Bool = true
        /// Scheme, configuration and destination of the build (v0.4); nil leaves `build.scheme` etc. null.
        public var buildContext: BuildContext?
        /// `build --deep` (v0.5 lane A): what was injected and where the deep readers look; nil leaves `deep` null.
        public var deep: DeepRun?
        /// v0.5 integration: an `.xcodeproj` read-only (`ModuleGraph.fallbackProject`) for the module graph's edges when
        /// no build description has `target-graph.txt` (`moduleGraph.source` `project`); nil leaves the log fallback.
        public var project: ProjectModel?

        public init(topN: Int = 15, budgetBytes: Int = Validator.defaultBudgetBytes, generatedAt: Date = Date(),
                    inputPath: String? = nil, environment: EnvSnapshot? = nil,
                    buildDescription: BuildDescription? = nil, physicalCores: Int? = nil, processWall: Double? = nil) {
            self.environment = environment
            self.buildDescription = buildDescription
            self.physicalCores = physicalCores
            self.processWall = processWall
            self.topN = topN
            self.budgetBytes = budgetBytes
            self.generatedAt = generatedAt
            self.inputPath = inputPath
        }
    }

    public struct Result: Sendable {
        public var analysis: Analysis
        public var validation: ValidationReport
        public var document: ReportDocument
    }

    /// V13 needs the serialized size, which depends on the validation section: the size is measured on a first pass
    /// (validation without V13) and the final report carries V13 computed from it. The final file differs from that
    /// measurement only by the V13 line. The v0.2 engines run once and serve both passes; `Result.validation` carries
    /// their V3, V9 and V11, so it matches `document.validation` check for check.
    public static func run(_ model: BuildModel, options: Options = Options()) throws -> Result {
        let analysis = Timing.analyze(model, topN: options.topN)
        let xcode = XcodeVersionInference.infer(from: model)
        let explain = Explain.run(model: model, analysis: analysis, description: options.buildDescription,
                                  physicalCores: options.physicalCores, deep: options.deep, project: options.project)
        let first = Validator.validate(model, analysis: analysis, serializedBytes: nil, budgetBytes: options.budgetBytes)
        let made = ReportDocument.make(model: model, analysis: analysis, validation: first,
                                        generatedAt: options.generatedAt, inputPath: options.inputPath,
                                        xcode: xcode, environment: options.environment,
                                        buildDescription: options.buildDescription,
                                        processWall: options.processWall, deep: options.deep, explain: explain)
        let draft = options.buildContext.map { made.applying(buildContext: $0) } ?? made
        let size = try JSONReporter.render(draft).count
        let validation = Validator.validate(model, analysis: analysis, serializedBytes: options.checksSize ? size : nil,
                                            budgetBytes: options.budgetBytes)
        var document = ReportDocument.make(model: model, analysis: analysis, validation: validation,
                                           generatedAt: options.generatedAt, inputPath: options.inputPath,
                                           xcode: xcode, environment: options.environment,
                                           buildDescription: options.buildDescription,
                                           processWall: options.processWall, deep: options.deep, explain: explain)
        if let context = options.buildContext { document = document.applying(buildContext: context) }
        return Result(analysis: analysis, validation: validation.replacing(explain.checks), document: document)
    }
}

extension ReportDocument {
    /// `build.scheme`, `.configuration` and `.destination` from the build context; a nil member stays null.
    public func applying(buildContext context: BuildContext) -> ReportDocument {
        var document = self
        document.build.scheme = context.scheme
        document.build.configuration = context.configuration
        document.build.destination = context.destination
        return document
    }

    /// `incremental` set, and the V15 check row replaced by `Validator.checkV15` over it (v0.5; lane B fills the check).
    /// A failed V15 marks the report degraded like any failed check (§6.11). Callers run V13 again afterwards
    /// (`remeasuringSize`) when they measure size.
    public func applying(incremental: Incremental?) -> ReportDocument {
        var document = self
        document.incremental = incremental
        let check = Validator.checkV15(incremental, executedSeconds: build.taskTime)
        document.validation.checks = document.validation.checks.map {
            $0.id == "V15" ? Check(id: $0.id, title: $0.title, status: check.status.label, detail: check.detail) : $0
        }
        if let reason = check.degradingReason {
            let entry = DegradationEntry(kind: "validation", detail: "V15: \(reason)")
            if !document.degradations.contains(entry) { document.degradations.append(entry) }
            document.degraded = true
            document.validation.degraded = true
        }
        return document
    }

    /// V13 measured again on this document, V13 line included (the pipeline measured before `merge(rules:)` added
    /// findings, `doctor` and `project`). A `notApplicable` V13 (html, measured on the page) is left alone.
    public func remeasuringSize(budgetBytes: Int) throws -> ReportDocument {
        guard validation.checks.contains(where: { $0.id == "V13" && $0.status != CheckStatus.notApplicable.label }) else {
            return self
        }
        func pass(_ size: Int) -> ReportDocument {
            var document = self
            let check = Validator.checkV13(serializedBytes: size, budgetBytes: budgetBytes)
            document.validation.checks = document.validation.checks.map {
                $0.id == "V13" ? Check(id: $0.id, title: $0.title, status: check.status.label, detail: check.detail) : $0
            }
            return document
        }
        // Twice: the second pass only differs when the size changed its digit count.
        let first = pass(try JSONReporter.render(self).count)
        return pass(try JSONReporter.render(first).count)
    }
}

// MARK: - Output

extension ReportPipeline {
    /// The last step before any reporter, for every format: non-finite numbers become null with a note
    /// (`DocumentSanitizer`), then the Redactor runs when `redact` is set. Throws `outputAborted` rather than return a
    /// document that cannot be written or that `--redact` could not clean, so the command writes nothing.
    public static func prepareForOutput(_ document: ReportDocument, redact: Bool,
                                        context: @autoclosure () -> Redactor.Context = .current()) throws -> ReportDocument {
        redact ? try Redactor.redact(document, context: context()) : try DocumentSanitizer.sanitize(document)
    }

    public static func prepareForOutput(_ document: CompareDocument, redact: Bool,
                                        context: @autoclosure () -> Redactor.Context = .current()) throws -> CompareDocument {
        redact ? try Redactor.redact(document, context: context()) : try DocumentSanitizer.sanitize(document)
    }

    public static func prepareForOutput(_ document: TrendDocument, redact: Bool,
                                        context: @autoclosure () -> Redactor.Context = .current()) throws -> TrendDocument {
        redact ? try Redactor.redact(document, context: context()) : try DocumentSanitizer.sanitize(document)
    }
}

// MARK: - v0.4 text formats (docs/SCHEMA-v0.4.md "Formats")

/// Everything a v0.4 text reporter (`markdown`, `github`, `junit`, `agent`) needs besides the document.
public struct FormatOptions: Sendable {
    /// Hard cap in bytes (UTF-8) of the rendered body: `--max-report-bytes`, else `ReportBudget.Format.defaultMaxBytes`.
    public var maxBytes: Int
    /// `<xcblame-dir>/config.json`, read by `junit` for its budgets; nil or absent file means no budgets.
    public var configURL: URL?
    /// The command that reproduces the report with full detail (`xcblame analyze <input> --format json --top all`),
    /// printed in truncation footers; nil leaves the footer generic.
    public var reproduceCommand: String?
    /// Repository root of the checkout (`$GITHUB_WORKSPACE`, else the git root of the current directory), for the
    /// repo-relative `file=` of `github` annotations; nil when unknown. A redacted document names it `$REPO`.
    public var workspaceRoot: String?

    public init(maxBytes: Int, configURL: URL? = nil, reproduceCommand: String? = nil, workspaceRoot: String? = nil) {
        self.maxBytes = maxBytes
        self.configURL = configURL
        self.reproduceCommand = reproduceCommand
        self.workspaceRoot = workspaceRoot
    }
}

/// What a text reporter produced: the body, plus `::warning`/`::error` workflow commands for `github`.
public struct FormatOutput: Sendable, Equatable {
    public var body: String
    /// GitHub workflow commands, one per element, no trailing newline; empty for every format but `github`.
    public var annotations: [String]

    public init(body: String, annotations: [String] = []) {
        self.body = body
        self.annotations = annotations
    }
}

extension ReportPipeline {
    /// Routes a document to the reporter of `format`. The document is already redacted when the CLI asked for it.
    /// Throws `notImplemented` until Lane A fills the reporters; `json`, `html` and `text` are not routed here.
    public static func renderFormat(_ document: ReportDocument, format: ReportBudget.Format,
                                    options: FormatOptions) throws -> FormatOutput {
        switch format {
        case .markdown: return FormatOutput(body: try MarkdownReporter.render(document, options: options))
        case .github: return try GitHubReporter.render(document, options: options)
        case .junit: return FormatOutput(body: try JUnitReporter.render(document, options: options))
        case .agent: return FormatOutput(body: try AgentReporter.render(document, options: options))
        case .text, .json, .html:
            throw XcblameError.usage("\(format.rawValue) is not a v0.4 text format")
        }
    }
}
