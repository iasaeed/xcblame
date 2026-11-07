import Foundation
import XCTest
@testable import XcblameKit

/// `fixtures/deep/` (stats-dir JSON, ftime-trace JSON, toolchain help excerpts) and synthetic models whose compile
/// tasks carry command lines, for the lane A tests.
enum DeepFixtures {
    static let root = SLFFixtures.root.deletingLastPathComponent().appendingPathComponent("deep")
    static let stats26 = root.appendingPathComponent("stats/xcode26")
    static let stats27 = root.appendingPathComponent("stats/xcode27.1b")
    static let trace26 = root.appendingPathComponent("ftime-trace/xcode26-PlatformMutex.json")
    static let trace27 = root.appendingPathComponent("ftime-trace/xcode27.1b-PlatformMutex.json")
    static let commonArgs26 = root.appendingPathComponent("ftime-trace/xcode26-common-args.resp")
    static let toolchain = root.appendingPathComponent("toolchain")

    static func text(_ name: String) throws -> String {
        try String(contentsOf: toolchain.appendingPathComponent(name), encoding: .utf8)
    }

    /// The Xcode 26.0.1 help texts as the probe returns them (`-help` then `-help-hidden`).
    static func probe26() throws -> ToolchainProbe.Result {
        ToolchainProbe.Result(
            swiftFrontendHelp: try text("xcode26-swift-frontend-help.txt") + "\n"
                + text("xcode26-swift-frontend-help-hidden-excerpt.txt"),
            clangHelp: try text("xcode26-clang-help-excerpt.txt"))
    }

    /// A scratch folder removed after the test.
    static func scratch(_ test: XCTestCase) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("xcblame-deep-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        test.addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// The synthetic model with target 1 renamed `AcmeApp` (the stats fixtures' module) and command lines on some
    /// compile tasks: `perFile` (one primary file, `StudioView.swift`), a 3-file batch of target 2, and the App
    /// target's `CompileC` writing `object`.
    struct Model {
        var model: BuildModel
        var perFileTask: Int
        var batchTask: Int
        var batchFiles: [String]
        var clangTask: Int
    }

    static func model(object: String = "/dd/Objects-normal/arm64/Bridge.o") -> Model {
        var model = SyntheticModel.make()
        model.targets[1].name = "AcmeApp"
        model.targets[2].name = "NetKit"
        let swift = model.tasks.filter { $0.ruleName == "SwiftCompile" }
        let perFile = swift.first { $0.targetId == 1 }!.id
        let batch = swift.first { $0.targetId == 2 }!.id
        let clang = model.tasks.first { $0.ruleName == "CompileC" }!.id
        model.tasks[perFile].commandDetails =
            "SwiftCompile normal arm64 /src/AcmeApp/StudioView.swift (in target 'AcmeApp' from project 'AcmeApp')\n"
        let batchFiles = ["/src/NetKit/A.swift", "/src/NetKit/B.swift", "/src/NetKit/C.swift"]
        model.tasks[batch].commandDetails = "SwiftCompile normal arm64 " + batchFiles.joined(separator: " ")
            + " (in target 'NetKit' from project 'NetKit')\n"
        model.tasks[clang].commandDetails = "CompileC \(object) /src/App/Bridge.m normal arm64 objective-c "
            + "com.apple.compilers.llvm.clang.1_0.compiler (in target 'App' from project 'App')\n    cd /src\n"
            + "    clang -x objective-c @/dd/Objects-normal/arm64/abc-common-args.resp -c /src/App/Bridge.m -o \(object)\n"
        return Model(model: model, perFileTask: perFile, batchTask: batch, batchFiles: batchFiles, clangTask: clang)
    }

    static func deepRun(statsDir: URL, scope: [DeepScope] = [.swift, .clang], enabled: Bool = true) -> DeepRun {
        let injected = ["-Xfrontend -debug-time-function-bodies", "-Xfrontend -stats-output-dir -Xfrontend \(statsDir.path)",
                        "-ftime-trace", "-ftime-trace-granularity=500"]
        let flags = DeepFlags(scope: scope, exactFiles: false, lines: [], injected: injected, dropped: [])
        return DeepRun(flags: flags, enabled: enabled, derivedData: statsDir.deletingLastPathComponent(),
                       derivedDataBytes: nil, statsDir: statsDir, wrapper: nil, shadowed: [], exactFiles: nil, notes: [])
    }
}
