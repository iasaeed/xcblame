import Foundation

/// Machine facts the ENV rules read beyond `EnvSnapshot`: Xcode defaults, the DerivedData volume, Time Machine,
/// installed Xcode copies. Every probe is read-only with the 2 s `runProbe` timeout; nil means unknown. Tests swap
/// the probe through `MachineProbe.$current.withValue`.
// ponytail: EnvSnapshot (frozen, Env/) has no Xcode-defaults fields, so the ENV rules probe here; move these into
// EnvSnapshot if a later schema adds them.
struct MachineProbe: Sendable {
    /// argv → trimmed stdout, nil on failure.
    var run: @Sendable ([String]) -> String?
    /// The path is a symbolic link.
    var isSymlink: @Sendable (String) -> Bool
    /// Available / total bytes of the volume holding the path.
    var freeShare: @Sendable (String) -> Double?
    /// `Xcode*.app` bundles in /Applications.
    var xcodeApps: @Sendable () -> [String]
    var homeDirectory: String

    @TaskLocal static var current = MachineProbe.live

    static let live = MachineProbe(
        run: { runProbe($0, timeout: 2) },
        isSymlink: { path in
            ((try? FileManager.default.attributesOfItem(atPath: path))?[.type] as? FileAttributeType) == .typeSymbolicLink
        },
        freeShare: { path in
            let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeAvailableCapacityKey,
                                                                                  .volumeTotalCapacityKey])
            guard let free = values?.volumeAvailableCapacity, let total = values?.volumeTotalCapacity, total > 0 else {
                return nil
            }
            return Double(free) / Double(total)
        },
        xcodeApps: {
            ((try? FileManager.default.contentsOfDirectory(atPath: "/Applications")) ?? [])
                .filter { $0.hasPrefix("Xcode") && $0.hasSuffix(".app") }.sorted()
        },
        homeDirectory: NSHomeDirectory())

    /// `defaults read com.apple.dt.Xcode <key>`; nil when unset.
    func xcodeDefault(_ key: String) -> String? { run(["defaults", "read", "com.apple.dt.Xcode", key]) }

    /// The DerivedData folder Xcode uses (`IDECustomDerivedDataLocation`, else the default under ~/Library).
    func derivedDataPath() -> String {
        if let custom = xcodeDefault("IDECustomDerivedDataLocation"), !custom.isEmpty {
            return NSString(string: custom).expandingTildeInPath
        }
        return homeDirectory + "/Library/Developer/Xcode/DerivedData"
    }
}
