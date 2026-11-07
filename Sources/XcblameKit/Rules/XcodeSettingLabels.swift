import Foundation

/// The names Xcode's Build Settings editor shows for the build settings the rule catalog reads, and for their values,
/// so a finding can say "Compilation Mode: Whole Module → Incremental" next to `SWIFT_COMPILATION_MODE = wholemodule`.
/// Keys without an entry are shown by their raw name (Xcode lists them under User-Defined).
public enum XcodeSettingLabels {
    /// key → (label in Build Settings, raw value → label in the value pop-up).
    static let table: [String: (label: String, values: [String: String])] = [
        "SWIFT_COMPILATION_MODE": ("Compilation Mode", ["singlefile": "Incremental", "wholemodule": "Whole Module"]),
        "SWIFT_OPTIMIZATION_LEVEL": ("Optimization Level", [
            "-Onone": "No Optimization [-Onone]", "-O": "Optimize for Speed [-O]", "-Osize": "Optimize for Size [-Osize]"]),
        "GCC_OPTIMIZATION_LEVEL": ("Optimization Level", [
            "0": "None [-O0]", "1": "Fast [-O, O1]", "2": "Faster [-O2]", "3": "Fastest [-O3]", "s": "Fastest, Smallest [-Os]",
            "fast": "Fastest, Aggressive Optimizations [-Ofast]", "z": "Smallest, Aggressive Size Optimizations [-Oz]"]),
        "DEBUG_INFORMATION_FORMAT": ("Debug Information Format", ["dwarf": "DWARF", "dwarf-with-dsym": "DWARF with dSYM File"]),
        "ONLY_ACTIVE_ARCH": ("Build Active Architecture Only", yesNo),
        "COPY_PHASE_STRIP": ("Strip Debug Symbols During Copy", yesNo),
        "ENABLE_TESTABILITY": ("Enable Testability", yesNo),
        "COMPILATION_CACHE_ENABLE_CACHING": ("Enable Compilation Caching", yesNo),
        "ENABLE_BITCODE": ("Enable Bitcode", yesNo),
        "VALIDATE_PRODUCT": ("Validate Built Product", yesNo),
        "LLVM_LTO": ("Link-Time Optimization", ["NO": "No", "YES": "Monolithic", "YES_THIN": "Incremental"]),
        "EXCLUDED_ARCHS": ("Excluded Architectures", [:]),
        "DEPLOYMENT_POSTPROCESSING": ("Deployment Postprocessing", yesNo),
        "USE_HEADERMAP": ("Use Header Maps", yesNo),
        "SWIFT_ENABLE_EXPLICIT_MODULES": ("Explicitly Built Modules", yesNo),
        "GCC_PRECOMPILE_PREFIX_HEADER": ("Precompile Prefix Header", yesNo),
        "GCC_PREFIX_HEADER": ("Prefix Header", [:]),
        "ENABLE_USER_SCRIPT_SANDBOXING": ("User Script Sandboxing", yesNo),
        "CLANG_ENABLE_MODULES": ("Enable Modules (C and Objective-C)", yesNo),
        "BUILD_LIBRARY_FOR_DISTRIBUTION": ("Build Libraries for Distribution", yesNo),
        "ALWAYS_SEARCH_USER_PATHS": ("Always Search User Paths (Deprecated)", yesNo),
        "DEFINES_MODULE": ("Defines Module", yesNo),
        "COMPILER_INDEX_STORE_ENABLE": ("Enable Index-While-Building Functionality", yesNo),
        "OTHER_SWIFT_FLAGS": ("Other Swift Flags", [:]),
        "OTHER_LDFLAGS": ("Other Linker Flags", [:]),
        "OTHER_CFLAGS": ("Other C Flags", [:]),
        "OTHER_CPLUSPLUSFLAGS": ("Other C++ Flags", [:]),
        "HEADER_SEARCH_PATHS": ("Header Search Paths", [:]),
        "USER_HEADER_SEARCH_PATHS": ("User Header Search Paths", [:]),
        "SWIFT_VERSION": ("Swift Language Version", [:]),
    ]

    private static let yesNo = ["YES": "Yes", "NO": "No"]

    /// The Build Settings label of `key`, nil for a key Xcode shows under User-Defined.
    public static func label(_ key: String) -> String? { table[key]?.label }

    /// The value as Xcode's pop-up shows it (`wholemodule` → `Whole Module`), nil when it has no label.
    public static func value(_ key: String, _ value: String) -> String? { table[key]?.values[value] }

    /// `Compilation Mode: Whole Module (SWIFT_COMPILATION_MODE = wholemodule)`; the raw form when there is no label.
    public static func describe(_ key: String, _ raw: String?) -> String {
        guard let label = label(key) else { return "\(key) = \(raw ?? "unset") (User-Defined)" }
        guard let raw else { return "\(label) (\(key)): not set" }
        return "\(label): \(value(key, raw) ?? raw) (\(key) = \(raw))"
    }

    /// The Build Settings row for a key: `Compilation Mode (SWIFT_COMPILATION_MODE)` or `User-Defined › KEY`.
    public static func row(_ key: String) -> String {
        label(key).map { "\($0) (\(key))" } ?? "User-Defined › \(key)"
    }

    /// One "where to change it in Xcode" line for a setting change: `Build Settings › Compilation Mode
    /// (SWIFT_COMPILATION_MODE), Debug: Whole Module → Incremental`.
    public static func changeLine(key: String, from: String?, to: String, configurations: [String], targets: String) -> String {
        let scope = (targets.isEmpty ? "" : targets + ", ") + (configurations.isEmpty ? "all configurations" : configurations.joined(separator: " and "))
        let old = from.map { value(key, $0) ?? $0 }
        let new = value(key, to) ?? to
        return "Build Settings › \(row(key)) for \(scope): " + (old.map { "\($0) → " } ?? "set to ") + new
            + (new.lowercased() != to.lowercased() && !new.contains("[") ? " (\(to))" : "")
    }
}
