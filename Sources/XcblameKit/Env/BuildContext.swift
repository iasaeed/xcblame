import Foundation

/// Which scheme, configuration and destination a build ran with (`build.scheme`, `.configuration`, `.destination`;
/// docs/SCHEMA-v0.4.md "Build context"). Baselines, compare and trend key on it. The commands pass it through
/// `ReportPipeline.Options.buildContext`.
public struct BuildContext: Sendable, Equatable {
    /// `-scheme`.
    public var scheme: String?
    /// `-configuration`.
    public var configuration: String?
    /// Normalized destination, `platform [arch]`: `macOS arm64`, `iOS Simulator`. One vocabulary for the `-destination`
    /// specifier and the build request; never a device name, an id or an OS version.
    public var destination: String?

    public init(scheme: String? = nil, configuration: String? = nil, destination: String? = nil) {
        self.scheme = scheme
        self.configuration = configuration
        self.destination = destination
    }

    // MARK: - Sources

    /// `-scheme`, `-configuration` and `-destination` of an xcodebuild command line (the arguments after `xcblame
    /// build --`). Both `-name value` and `-name=value` are read; the first of a repeated flag wins (a build with
    /// several destinations has no single one to key on, the first is the primary).
    public static func from(xcodebuildArguments arguments: [String]) -> BuildContext {
        func value(_ flag: String) -> String? {
            for (index, argument) in arguments.enumerated() {
                if argument == flag, arguments.indices.contains(index + 1) {
                    let next = arguments[index + 1]
                    return next.isEmpty ? nil : next
                }
                if argument.hasPrefix(flag + "="), argument.count > flag.count + 1 { return String(argument.dropFirst(flag.count + 1)) }
            }
            return nil
        }
        return BuildContext(scheme: value("-scheme"), configuration: value("-configuration"),
                            destination: value("-destination").flatMap(humanDestination(of:)))
    }

    /// The scheme the Xcode log manifest recorded for the log (`LogStoreManifest.plist`); nothing else is known.
    public static func from(manifestScheme scheme: String?) -> BuildContext {
        BuildContext(scheme: scheme?.isEmpty == false ? scheme : nil)
    }

    /// Configuration and destination from the build description's `build-request.json` (its flattened scalars, see
    /// `BuildDescription.BuildRequest.raw`): `configurationName` and `activeRunDestination`. The request names no
    /// scheme.
    public static func from(buildRequest raw: [String: String]) -> BuildContext {
        let platforms = ["macosx": "macOS", "iphonesimulator": "iOS Simulator", "iphoneos": "iOS",
                         "appletvsimulator": "tvOS Simulator", "appletvos": "tvOS",
                         "watchsimulator": "watchOS Simulator", "watchos": "watchOS",
                         "xrsimulator": "visionOS Simulator", "xros": "visionOS",
                         "driverkit": "DriverKit"]
        var destination: String?
        if let platform = raw["parameters.activeRunDestination.platform"].flatMap({ platforms[$0] }) {
            // A Mac build with another SDK variant is another destination (Catalyst, an iPad app on the Mac).
            let variant: String? = switch raw["parameters.activeRunDestination.sdkVariant"] {
            case "iosmac": "Mac Catalyst"
            case "iphoneos", "iphonesimulator": platform == "macOS" ? "Designed for iPad" : nil
            default: nil
            }
            destination = [variant ?? platform, raw["parameters.activeRunDestination.targetArchitecture"]]
                .compactMap { $0 }.joined(separator: " ")
        }
        return BuildContext(configuration: raw["parameters.configurationName"].flatMap { $0.isEmpty ? nil : $0 },
                            destination: destination)
    }

    /// This context, with every member it lacks taken from `fallback`.
    public func filling(from fallback: BuildContext) -> BuildContext {
        BuildContext(scheme: scheme ?? fallback.scheme, configuration: configuration ?? fallback.configuration,
                     destination: destination ?? fallback.destination)
    }

    /// One line for `build.notes` naming what is unknown and why, nil when everything is known. `source` says where
    /// the context was looked for (`"the xcodebuild arguments"`, `"the log"`).
    public func missingNote(source: String) -> String? {
        let missing = [("scheme", scheme), ("configuration", configuration), ("destination", destination)]
            .filter { $0.1 == nil }.map(\.0)
        guard !missing.isEmpty else { return nil }
        return "build context: \(missing.joined(separator: ", ")) not found in \(source); the report keeps them null"
    }

    // MARK: - Destination

    /// Architectures that end a normalized destination (`macOS arm64`); a platform name never ends in one.
    private static let architectures: Set<String> = ["arm64", "arm64e", "arm64_32", "x86_64", "i386", "armv7", "armv7k", "armv7s"]

    /// Platform and architecture of a normalized destination (`iOS Simulator arm64` is `("iOS Simulator", "arm64")`).
    static func parts(ofDestination destination: String) -> (platform: String, arch: String?) {
        let words = destination.split(separator: " ").map(String.init)
        guard words.count > 1, let last = words.last, architectures.contains(last) else { return (destination, nil) }
        return (words.dropLast().joined(separator: " "), last)
    }

    /// Whether two destinations are the same one: an unknown side agrees with anything, the platforms must be equal and
    /// the architectures are compared only when both sides have one (`build -destination platform=macOS` against a log
    /// whose build request says `macOS arm64`).
    public static func destinationsAgree(_ x: String?, _ y: String?) -> Bool {
        guard let x, let y else { return true }
        let (left, right) = (parts(ofDestination: x), parts(ofDestination: y))
        return left.platform == right.platform && (left.arch == nil || right.arch == nil || left.arch == right.arch)
    }

    /// The most specific of destinations that agree: the one that names an architecture, else the first.
    static func mergedDestination(_ values: [String]) -> String? {
        values.first { parts(ofDestination: $0).arch != nil } ?? values.first
    }

    /// Platform and variant names with their canonical spelling, keyed by lowercase (`platform=macos` is `macOS`).
    private static let canonicalNames: [String: String] = Dictionary(uniqueKeysWithValues: [
        "macOS", "iOS", "iOS Simulator", "tvOS", "tvOS Simulator", "watchOS", "watchOS Simulator", "visionOS",
        "visionOS Simulator", "DriverKit", "Mac Catalyst", "Designed for iPad",
    ].map { ($0.lowercased(), $0) })

    /// A normalized destination from an `-destination` specifier, without device names, ids or OS versions:
    /// `platform=iOS Simulator,name=iPhone 17,OS=26.0` is `iOS Simulator`; `platform=macOS,arch=arm64` is
    /// `macOS arm64`; `generic/platform=iOS` and `platform=iOS,id=<udid>` are `iOS`. A variant replaces the platform
    /// (`platform=macOS,variant=Mac Catalyst` is `Mac Catalyst`, `variant=Designed for iPad` is `Designed for iPad`),
    /// since it is another build of the app. Platform and variant names are case-folded to their canonical spelling.
    /// Nil when the specifier names no platform.
    public static func humanDestination(of specifier: String) -> String? {
        var fields: [String: String] = [:]
        for part in specifier.split(separator: ",") {
            var piece = part.trimmingCharacters(in: .whitespaces)
            if piece.hasPrefix("generic/") { piece = String(piece.dropFirst("generic/".count)) }
            guard let equals = piece.firstIndex(of: "=") else { continue }
            fields[String(piece[..<equals]).lowercased()] = String(piece[piece.index(after: equals)...])
        }
        guard let platform = fields["platform"], !platform.isEmpty else { return nil }
        func canonical(_ name: String) -> String { canonicalNames[name.lowercased()] ?? name }
        let name = fields["variant"].flatMap { $0.isEmpty ? nil : canonical($0) } ?? canonical(platform)
        return [name, fields["arch"].flatMap { $0.isEmpty ? nil : $0 }].compactMap { $0 }.joined(separator: " ")
    }
}
