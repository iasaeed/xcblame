import Foundation

// v0.5 lane B (docs/SCHEMA-v0.5.md "Cause attribution"): evidence providers are pluggable, one per `source`, so the
// probe results (MV-2 backtraces, MV-8 driver remarks) change one provider, not the engine.

/// `incremental.causes[].source`, in the precedence order of DESIGN §6.6 (the first that applies is primary).
public enum EvidenceSource: String, Sendable, CaseIterable, Codable, Comparable {
    case backtrace, script, signature, upstreamInterface, mtimeChurn, planning, driverRemark, unknown

    /// 0 is the strongest.
    public var precedence: Int { Self.allCases.firstIndex(of: self)! }

    public static func < (lhs: EvidenceSource, rhs: EvidenceSource) -> Bool { lhs.precedence < rhs.precedence }
}

/// `incremental.causes[].class` (`ReportDocument.Incremental.classes`).
public enum CauseClass: String, Sendable, CaseIterable, Codable {
    case inputChanged, scriptPhase, settingsChanged, upstreamInterface, timestampChurn, planning, firstBuild, forced
    case driverRemark, unknown
}

/// One piece of evidence about one executed task.
public struct CauseEvidence: Sendable, Equatable {
    public var source: EvidenceSource
    public var cls: CauseClass
    /// Model task id the evidence is about.
    public var taskId: Int
    /// Upstream task this one was rebuilt for (`ruleInputRebuilt`); the engine follows it to the root cause.
    public var rootTaskId: Int?
    /// File, target, phase or setting it points at; the cause id is `<class>:<subject>`.
    public var subject: String?
    /// One line, without the source prefix.
    public var detail: String
    public var ruleId: String?

    public init(source: EvidenceSource, cls: CauseClass, taskId: Int, rootTaskId: Int? = nil, subject: String?,
                detail: String, ruleId: String? = nil) {
        self.source = source
        self.cls = cls
        self.taskId = taskId
        self.rootTaskId = rootTaskId
        self.subject = subject
        self.detail = detail
        self.ruleId = ruleId
    }
}

/// What every provider may read. Pure data: providers never run processes.
public struct CauseContext: Sendable {
    public var model: BuildModel
    /// Model task ids that entered timing (executed, not reused).
    public var executedTaskIds: [Int]
    public var currentRows: [History.TaskIndexRow]
    public var previous: PreviousIndex?
    public var matches: [TaskIdentity.Match]
    public var project: ProjectModel?
    /// Output and input hashes captured by `why` (nil under `analyze`).
    public var capture: OutputHashes.Capture?
    /// Inferred Xcode version (DYN-005 and ENV-008 gates).
    public var xcode: String?
    /// Target name → names of the targets it depends on (module graph edges or the project), for picking which
    /// changed upstream module a downstream compile depends on; empty when unknown.
    public var targetDependencies: [String: Set<String>] = [:]

    public init(model: BuildModel, executedTaskIds: [Int], currentRows: [History.TaskIndexRow],
                previous: PreviousIndex?, matches: [TaskIdentity.Match], project: ProjectModel?,
                capture: OutputHashes.Capture?, xcode: String?) {
        self.model = model
        self.executedTaskIds = executedTaskIds
        self.currentRows = currentRows
        self.previous = previous
        self.matches = matches
        self.project = project
        self.capture = capture
        self.xcode = xcode
    }
}

/// One evidence source. Providers are independent; `CauseEngine` keeps, per task, the highest-precedence evidence as
/// primary and the rest as secondary.
public protocol CauseEvidenceProvider: Sendable {
    var source: EvidenceSource { get }
    func evidence(in context: CauseContext) -> [CauseEvidence]
}

/// The previous build of the same build key from history (`History.previousIndex`).
public struct PreviousIndex: Sendable, Equatable {
    public var id: String
    /// When the entry was recorded (its id's time stamp: the report time, at or after the build's end).
    public var time: Date?
    public var kind: String?
    public var rows: [History.TaskIndexRow]
    /// Its log span in seconds; `time - span` approximates when that build started (timestamp churn, §6.6 step 5).
    public var span: Double?

    public init(id: String, time: Date?, kind: String?, rows: [History.TaskIndexRow], span: Double? = nil) {
        self.id = id
        self.time = time
        self.kind = kind
        self.rows = rows
        self.span = span
    }

    /// Approximate start of the previous build: `time - span` (`time` without a span); nil without a time.
    public var start: Date? { time.map { $0.addingTimeInterval(-max(0, span ?? 0)) } }
}
