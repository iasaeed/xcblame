import Foundation

/// One rule of docs/RULES.md as a value (DESIGN §7.1). Lane C writes the catalog as Swift literals.
public struct RuleSpec: Codable, Sendable, Equatable {
    /// ID prefix = category (RULES.md §0).
    public enum Category: String, Codable, Sendable, Equatable, CaseIterable {
        case set, src, graph, phase, dep, env, ci, dyn

        /// `SET`, `PHASE`, ...: the ID prefix.
        public var prefix: String { rawValue.uppercased() }

        /// Signal-dedupe order (RULES.md §10): SET > PHASE > DEP > GRAPH > SRC > ENV > DYN; CI after DYN.
        public var dedupeRank: Int {
            [.set, .phase, .dep, .graph, .src, .env, .dyn, .ci].firstIndex(of: self) ?? .max
        }
    }

    /// RULES.md `Det`.
    public enum Detection: String, Codable, Sendable, Equatable {
        /// `S`.
        case `static`
        /// `D`.
        case dynamic
        /// `S+D`.
        case both
        /// `info`: docs-only, never emitted as a finding.
        case info
    }

    /// RULES.md `Apply` (DESIGN §7.3).
    public enum ApplyKind: String, Codable, Sendable, Equatable, CaseIterable {
        case overlayDebug, overlayRelease, overlay, cli, defaults, scheme, pbxproj, manifest, recommend, measure

        /// RULES.md notation: `overlay(D)`, `overlay(R)`, `rec`, ...
        public var label: String {
            switch self {
            case .overlayDebug: return "overlay(D)"
            case .overlayRelease: return "overlay(R)"
            case .recommend: return "rec"
            default: return rawValue
            }
        }
    }

    /// RULES.md `Cfg`, matched by role (`ConfigurationRole`).
    public enum Configurations: String, Codable, Sendable, Equatable {
        case debug, release, both, ci
    }

    /// RULES.md `Ev`. Encodes as the tag text: `P`, `S`, `K`, or the mixed text (`S/K`, `P/K`).
    public enum EvidenceTag: Codable, Sendable, Equatable {
        case primary, secondary, knowledge
        case mixed(String)

        public var text: String {
            switch self {
            case .primary: return "P"
            case .secondary: return "S"
            case .knowledge: return "K"
            case let .mixed(text): return text
            }
        }

        /// Any `K` part gates the rule as [K]: confidence `low`, "needs measurement", `+V` only (RULES.md §0).
        public var isKnowledgeGated: Bool { text.contains("K") }

        public init(text: String) {
            switch text {
            case "P": self = .primary
            case "S": self = .secondary
            case "K": self = .knowledge
            default: self = .mixed(text)
            }
        }

        public init(from decoder: Decoder) throws {
            self.init(text: try decoder.singleValueContainer().decode(String.self))
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(text)
        }
    }

    /// Finding severity, the scale `--fail-on` compares against (docs/SCHEMA-v0.3.md).
    public enum Severity: String, Codable, Sendable, Equatable, CaseIterable, Comparable {
        case info, low, medium, high

        public static func < (lhs: Severity, rhs: Severity) -> Bool {
            allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
        }
    }

    /// `SET-001`.
    public var id: String
    /// `swift-compilation-mode-per-config`.
    public var name: String
    public var category: Category
    public var detection: Detection
    /// RULES.md "Exact signal", verbatim.
    public var signal: String
    /// RULES.md "Fix", verbatim.
    public var fix: String
    /// Every apply kind the row lists, in order; empty for `info` rows.
    public var applyKinds: [ApplyKind]
    /// `+V`: applied only through `xcblame verify`.
    public var verifyOnly: Bool
    /// RULES.md "Impact" text: catalog context, never a measurement.
    public var impactContext: String
    public var risk: String
    public var configurations: Configurations
    /// RULES.md "Xcode", e.g. `all`, `26+`, `16.4-26`.
    public var xcode: String
    public var evidenceTag: EvidenceTag
    /// Source URLs (the [OC] S-index resolved to links where one exists, else the source key).
    public var sources: [String]
    /// Rule ids this one conflicts with or defers to (RULES.md §10), e.g. `SET-015`.
    public var conflicts: [String]
    /// `signalKey` pattern, e.g. `setting:SWIFT_COMPILATION_MODE:<target>:<config>`, `script-phase:<phase-id>`.
    public var signalKeyTemplate: String
    /// One paragraph for `rules explain` and `ruleDocs`.
    public var summary: String
    /// Severity a finding of this rule gets unless the engine has a reason to change it (Lane C policy).
    public var severity: Severity

    public init(id: String, name: String, category: Category, detection: Detection, signal: String, fix: String,
                applyKinds: [ApplyKind], verifyOnly: Bool, impactContext: String, risk: String,
                configurations: Configurations, xcode: String, evidenceTag: EvidenceTag, sources: [String],
                conflicts: [String], signalKeyTemplate: String, summary: String, severity: Severity) {
        self.id = id
        self.name = name
        self.category = category
        self.detection = detection
        self.signal = signal
        self.fix = fix
        self.applyKinds = applyKinds
        self.verifyOnly = verifyOnly
        self.impactContext = impactContext
        self.risk = risk
        self.configurations = configurations
        self.xcode = xcode
        self.evidenceTag = evidenceTag
        self.sources = sources
        self.conflicts = conflicts
        self.signalKeyTemplate = signalKeyTemplate
        self.summary = summary
        self.severity = severity
    }

    /// The `ruleDocs` entry for this rule.
    public var ruleDoc: ReportDocument.RuleDoc {
        ReportDocument.RuleDoc(title: name, summary: summary, fix: fix, sources: sources, id: id,
                               category: category.prefix, applyKinds: applyKinds.map(\.label), verifyOnly: verifyOnly,
                               risk: risk, evidenceTag: evidenceTag.text)
    }

    /// `rules explain <id>` text: title, summary, signal, fix, apply kinds, risk, impact context, evidence tag,
    /// sources, conflicts.
    public var explainText: String {
        var lines = ["\(id)  \(name)  [\(category.prefix) · \(detection.rawValue) · \(configurations.rawValue) · "
            + "Xcode \(xcode) · [\(evidenceTag.text)]]", "", summary, "",
                     "signal   \(signal)", "fix      \(fix)",
                     "apply    " + (applyKinds.isEmpty ? "-" : applyKinds.map(\.label).joined(separator: ", "))
                         + (verifyOnly ? " +V (applied only through xcblame verify)" : ""),
                     "risk     \(risk)", "impact   \(impactContext)",
                     "evidence [\(evidenceTag.text)]" + (evidenceTag.isKnowledgeGated ? " needs measurement" : "")]
        if !conflicts.isEmpty { lines.append("conflicts " + conflicts.joined(separator: ", ")) }
        if !sources.isEmpty { lines.append("sources"); lines += sources.map { "  " + $0 } }
        return lines.joined(separator: "\n") + "\n"
    }
}

/// The rule catalog (Lane C fills `all` from docs/RULES.md).
public enum RuleCatalog {
    // ponytail: Swift literals, not catalog.json
    public static let all: [RuleSpec] = rules.map(\.spec)

    /// The v0.3 rules with their predicates, category by category (`Catalog+SET.swift`, ...).
    static let rules: [Rule] = setRules + phaseRules + depRules + envRules

    /// RULES.md alias ids (§1) to the rule they were merged into.
    static let aliases = ["PHASE-006": "PHASE-002", "SRC-010": "SET-007", "CI-005": "SET-008", "CI-007": "SET-017"]

    /// Case-insensitive; aliases resolve to their target rule.
    public static func spec(_ id: String) -> RuleSpec? {
        let wanted = resolve(id)
        return all.first { $0.id == wanted }
    }

    /// `set-001` → `SET-001`, `PHASE-006` → `PHASE-002`.
    static func resolve(_ id: String) -> String {
        let upper = id.uppercased()
        return aliases[upper] ?? upper
    }
}
