import Foundation

/// One catalog rule: the RULES.md row as a value plus the predicate that evaluates it (DESIGN §7.1).
// ponytail: predicates are plain closures next to their specs (one file per category), not a DSL or catalog.json.
struct Rule: Sendable {
    let spec: RuleSpec
    let evaluate: @Sendable (RuleScan) -> Evaluation
}

/// What a predicate concluded for one rule.
enum Evaluation {
    /// One or more finding candidates (one per signal: a phase, a package, or a rule's settings scope).
    case hits([RuleHit])
    /// The predicate held; the detail is the evidence (`Debug: singlefile`).
    case passed(String)
    /// Nothing to check, with the reason (`no script phases`, `no Debug-like configuration evaluated`).
    case notApplicable(String)
    /// Lost a RULES.md §10 conflict or waits for another rule; the detail names the winner.
    case suppressed(String)
}

/// A finding candidate before the engine adds shadowing, generator downgrade, confidence, band and commands.
struct RuleHit {
    /// One line, specific to this project (`SWIFT_COMPILATION_MODE = wholemodule in Debug for 4 targets`).
    var title: String
    var evidence: [ReportDocument.EvidenceItem]
    var targets: [String] = []
    var configurations: [String] = []
    /// The apply kind chosen for this signal (a row like `overlay (setting) / pbxproj (flag)` picks one).
    var apply: RuleSpec.ApplyKind
    /// Overlay assignments for `overlay*` kinds, written once per configuration in `configurations`.
    var overlay: [(key: String, value: String)] = []
    /// Values for the spec's `signalKeyTemplate` placeholders; `<targets>` and `<configs>` default to the scope.
    var keys: [String: String] = [:]
    /// Cost measured on the analyzed build; nil for static-only evidence.
    var measured: Measured?
    /// Overrides the catalog severity for this signal (still capped for [K] rules).
    var severity: RuleSpec.Severity?
    /// What to change in the generator source when the project is generated and the kind is `pbxproj`/`scheme`.
    var change: GeneratorChange?
    /// `cli` fixes: the `KEY=VALUE` arguments for the CI invocation.
    var cliArguments: [String] = []
    /// `xcblame verify --kind` for `+V` rules.
    var verifyKind = "clean"
}

/// A cost measured on the analyzed build (DESIGN §7.1 bands).
struct Measured: Equatable {
    var seconds: Double?
    var share: Double?
    var basis: String
}

/// The source edit a generated project needs instead of a pbxproj/scheme edit (RULES.md §10).
enum GeneratorChange {
    /// Set `key = value` for `configurations` (empty = all).
    case setting(key: String, value: String, configurations: [String])
    /// Remove `flag` from the list setting `key`.
    case removeFlag(key: String, flag: String)
    /// Declare inputs/outputs for a script phase.
    case scriptIO(phase: String, target: String)
    /// Guard a script phase to Release.
    case scriptGuard(phase: String, target: String)
    /// Pin a package to a version.
    case packagePin(url: String)
}
