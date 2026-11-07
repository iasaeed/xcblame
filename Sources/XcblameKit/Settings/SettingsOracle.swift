import Foundation

/// Effective build settings for one configuration (DESIGN §7.4): the ground truth rules read.
public struct EffectiveSettings: Codable, Sendable, Equatable {
    public enum Source: String, Codable, Sendable, Equatable {
        /// `xcodebuild -showBuildSettings -json`.
        case xcodebuild
        /// xcblame's own resolver over the project file and xcconfigs (`--offline`, or xcodebuild failed).
        case offlineResolver

        /// The text `project.settingsSource` shows.
        public var label: String {
            switch self {
            case .xcodebuild: return "xcodebuild -showBuildSettings -json"
            case .offlineResolver: return "offline resolver"
            }
        }
    }

    public var configuration: String
    /// Target name to its effective settings (fully expanded strings, as xcodebuild prints them). Package targets
    /// (xcodebuild never lists them, Xcode 26.0.1) come from local manifests through the offline resolver
    /// (`SWIFT_VERSION` only, with a note); remote package targets are absent.
    public var targets: [String: [String: String]]
    public var source: Source
    /// Fallbacks, timeouts, cache hits, targets the resolver could not expand.
    public var notes: [String]

    public init(configuration: String, targets: [String: [String: String]], source: Source, notes: [String] = []) {
        self.configuration = configuration
        self.targets = targets
        self.source = source
        self.notes = notes
    }
}

/// Which level set a setting's effective value (DESIGN §7.4, low to high).
public struct Provenance: Codable, Sendable, Equatable {
    public enum Level: String, Codable, Sendable, Equatable, CaseIterable {
        case platformDefault, projectXCConfig, projectSettings, targetXCConfig, targetSettings, commandLine, unknown
    }

    /// The highest level that assigns the key for this target and configuration.
    public var level: Level
    /// The file that assigns it: an xcconfig path (the including chain's leaf), or the `project.pbxproj`; nil for
    /// `platformDefault`, `commandLine` and `unknown`.
    public var file: String?
    /// The value as written at that level, unexpanded; nil when not written anywhere (platform default).
    public var rawValue: String?
    /// The winning assignment references `$(inherited)`, so lower levels still contribute.
    public var inherited: Bool

    public init(level: Level, file: String? = nil, rawValue: String? = nil, inherited: Bool = false) {
        self.level = level
        self.file = file
        self.rawValue = rawValue
        self.inherited = inherited
    }
}

/// Effective values and their provenance (Lane B).
public enum SettingsOracle {
    /// Effective settings for one configuration: `xcodebuild -showBuildSettings -json` over a scratch workspace in
    /// `cacheDir` whose generated scheme lists every project target (see `XcodebuildSettings`), cached in `cacheDir`
    /// keyed by the project file, xcconfig and manifest mtimes; with `offline` (or when xcodebuild fails, with a note)
    /// the offline resolver. Never writes outside `cacheDir`. Several configurations: `effectiveAll` runs them
    /// concurrently.
    public static func effective(project: ProjectModel, configuration: String, scheme: String?, offline: Bool,
                                 cacheDir: URL?) throws -> EffectiveSettings {
        effectiveAll(project: project, configurations: [configuration], scheme: scheme, offline: offline,
                     cacheDir: cacheDir)[configuration]!
    }

    /// Where `key` gets its value for `target` in `configuration`, from the project file and xcconfig chains
    /// (conditional keys and `$(inherited)` included): `platformDefault` when nothing sets it, `unknown` for a target
    /// the model does not have. `file` is relative to `project.root` when inside it.
    public static func provenance(project: ProjectModel, target: String, key: String,
                                  configuration: String) -> Provenance {
        provenance(project: project, target: target, key: key, configuration: configuration, commandLineOverrides: [:])
    }
}

/// Configuration roles (RULES.md §0): rules match configurations by role, not only by name.
public enum ConfigurationRole: String, Codable, Sendable, Equatable {
    case debugLike, releaseLike, unknown

    /// Debug-like: `SWIFT_OPTIMIZATION_LEVEL = -Onone`, or `DEBUG` in `SWIFT_ACTIVE_COMPILATION_CONDITIONS`.
    /// Release-like: an optimizing `SWIFT_OPTIMIZATION_LEVEL` (`-O`, `-Osize`, `-Ounchecked`, legacy
    /// `-Owholemodule`) without `DEBUG`. Without either setting the name decides (`Debug*` / `Release*`, any case),
    /// else `unknown`. A deliberately bad Debug (`-O` plus `DEBUG`) stays debug-like.
    public static func role(name: String, effective: [String: String]) -> ConfigurationRole {
        let conditions = (effective["SWIFT_ACTIVE_COMPILATION_CONDITIONS"] ?? "")
            .split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        let optimization = effective["SWIFT_OPTIMIZATION_LEVEL"]?.trimmingCharacters(in: .whitespaces)
        if optimization == "-Onone" || conditions.contains("DEBUG") { return .debugLike }
        if let optimization, optimization.hasPrefix("-O") { return .releaseLike }
        let lower = name.lowercased()
        if lower.hasPrefix("debug") { return .debugLike }
        if lower.hasPrefix("release") { return .releaseLike }
        return .unknown
    }
}
