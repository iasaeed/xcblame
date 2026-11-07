import XCTest
@testable import XcblameKit

final class BuildContextTests: XCTestCase {
    func testArgumentsGiveSchemeConfigurationAndDestination() {
        let context = BuildContext.from(xcodebuildArguments: [
            "-workspace", "AcmeApp.xcworkspace", "-scheme", "AcmeApp", "-configuration", "Release",
            "-destination", "platform=iOS Simulator,name=iPhone 17,OS=26.0", "build",
        ])
        XCTAssertEqual(context, BuildContext(scheme: "AcmeApp", configuration: "Release",
                                             destination: "iOS Simulator"))
    }

    func testEqualsFormAndFirstOfARepeatedFlag() {
        let context = BuildContext.from(xcodebuildArguments: [
            "-scheme=AcmeApp", "-destination", "platform=macOS,arch=arm64", "-destination", "platform=iOS", "test",
        ])
        XCTAssertEqual(context.scheme, "AcmeApp")
        XCTAssertNil(context.configuration)
        XCTAssertEqual(context.destination, "macOS arm64")
    }

    func testMissingArgumentsStayNilAndSayWhy() {
        let context = BuildContext.from(xcodebuildArguments: ["-project", "Acme.xcodeproj", "-scheme"])
        XCTAssertEqual(context, BuildContext())
        XCTAssertEqual(context.missingNote(source: "the arguments"),
                       "build context: scheme, configuration, destination not found in the arguments; the report keeps them null")
        XCTAssertNil(BuildContext(scheme: "A", configuration: "B", destination: "C").missingNote(source: "x"))
    }

    func testHumanDestinationNeverCarriesIdsOrOSVersions() {
        XCTAssertEqual(BuildContext.humanDestination(of: "platform=iOS Simulator,id=0A1B2C3D-0000-1111-2222-333344445555"),
                       "iOS Simulator")
        XCTAssertEqual(BuildContext.humanDestination(of: "platform=iOS,id=00008110-001234567890401E"), "iOS")
        XCTAssertEqual(BuildContext.humanDestination(of: "generic/platform=iOS"), "iOS")
        XCTAssertNil(BuildContext.humanDestination(of: "name=iPhone 17"))
    }

    /// Code review v0.4 re-check: the variant is part of the key (Catalyst is not native macOS), the platform name is
    /// case-folded, and the build request says the same as the arguments.
    func testVariantIsKeptAndPlatformNamesAreCaseFolded() {
        XCTAssertEqual(BuildContext.humanDestination(of: "platform=macOS,variant=Mac Catalyst,arch=arm64"), "Mac Catalyst arm64")
        XCTAssertEqual(BuildContext.humanDestination(of: "platform=macOS,variant=Mac Catalyst"), "Mac Catalyst")
        XCTAssertEqual(BuildContext.humanDestination(of: "platform=macOS,variant=Designed for iPad,arch=arm64"), "Designed for iPad arm64")
        XCTAssertEqual(BuildContext.humanDestination(of: "platform=macOS,variant=mac catalyst"), "Mac Catalyst")
        XCTAssertEqual(BuildContext.humanDestination(of: "platform=macos"), "macOS")
        XCTAssertEqual(BuildContext.humanDestination(of: "platform=ios simulator,name=iPhone 17"), "iOS Simulator")
        XCTAssertEqual(BuildContext.humanDestination(of: "platform=Brand New OS"), "Brand New OS", "an unknown platform stays as written")
        XCTAssertFalse(BuildContext.destinationsAgree("macOS arm64", BuildContext.humanDestination(of: "platform=macOS,variant=Mac Catalyst,arch=arm64")))
        let request = ["parameters.activeRunDestination.platform": "macosx", "parameters.activeRunDestination.targetArchitecture": "arm64"]
        XCTAssertEqual(BuildContext.from(buildRequest: request).destination, "macOS arm64")
        XCTAssertEqual(BuildContext.from(buildRequest: request.merging(["parameters.activeRunDestination.sdkVariant": "macosx"]) { $1 }).destination,
                       "macOS arm64", "the native variant adds nothing")
        XCTAssertEqual(BuildContext.from(buildRequest: request.merging(["parameters.activeRunDestination.sdkVariant": "iosmac"]) { $1 }).destination,
                       "Mac Catalyst arm64")
        XCTAssertEqual(BuildContext.from(buildRequest: request.merging(["parameters.activeRunDestination.sdkVariant": "iphoneos"]) { $1 }).destination,
                       "Designed for iPad arm64")
        XCTAssertEqual(BuildContext.from(xcodebuildArguments: ["-destination", "platform=macOS,variant=Mac Catalyst,arch=arm64"]).destination,
                       BuildContext.from(buildRequest: request.merging(["parameters.activeRunDestination.sdkVariant": "iosmac"]) { $1 }).destination)
    }

    /// Code review v0.4 M1: `build` (arguments) and `analyze` / log operands (build request) use one vocabulary,
    /// `platform [arch]`, so the same build has one key whichever way it was read.
    func testArgumentsAndBuildRequestShareOneDestinationVocabulary() {
        let request = ["parameters.configurationName": "Debug", "parameters.activeRunDestination.platform": "iphonesimulator",
                       "parameters.activeRunDestination.targetArchitecture": "arm64"]
        let fromRequest = BuildContext.from(buildRequest: request)
        XCTAssertEqual(fromRequest.destination, "iOS Simulator arm64")
        let fromArguments = BuildContext.from(xcodebuildArguments: ["-destination", "platform=iOS Simulator,name=iPhone 17,OS=26.0"])
        XCTAssertEqual(fromArguments.destination, "iOS Simulator", "no device name in the key")
        XCTAssertTrue(BuildContext.destinationsAgree(fromArguments.destination, fromRequest.destination),
                      "the platform alone decides when a side has no architecture")
        let macArguments = BuildContext.from(xcodebuildArguments: ["-destination", "platform=macOS"])
        XCTAssertEqual(macArguments.destination, "macOS")
        XCTAssertTrue(BuildContext.destinationsAgree("macOS", "macOS arm64"))
        XCTAssertTrue(BuildContext.destinationsAgree("macOS arm64", "macOS"))
        XCTAssertTrue(BuildContext.destinationsAgree("macOS arm64", "macOS arm64"))
        XCTAssertFalse(BuildContext.destinationsAgree("macOS arm64", "macOS x86_64"), "both name an architecture")
        XCTAssertFalse(BuildContext.destinationsAgree("macOS", "iOS Simulator arm64"))
        XCTAssertFalse(BuildContext.destinationsAgree("iOS", "iOS Simulator"), "a platform name is not a prefix match")
        XCTAssertTrue(BuildContext.destinationsAgree(nil, "macOS"), "unknown is not compared")
    }

    func testManifestSchemeAndBuildRequestFillWhatTheArgumentsLack() {
        let request = ["parameters.configurationName": "Debug", "parameters.activeRunDestination.platform": "macosx",
                       "parameters.activeRunDestination.targetArchitecture": "arm64"]
        XCTAssertEqual(BuildContext.from(buildRequest: request), BuildContext(configuration: "Debug", destination: "macOS arm64"))
        XCTAssertEqual(BuildContext.from(buildRequest: [:]), BuildContext())
        XCTAssertEqual(BuildContext.from(manifestScheme: ""), BuildContext())
        let merged = BuildContext.from(xcodebuildArguments: ["-configuration", "Release"])
            .filling(from: BuildContext.from(manifestScheme: "AcmeApp"))
            .filling(from: BuildContext.from(buildRequest: request))
        XCTAssertEqual(merged, BuildContext(scheme: "AcmeApp", configuration: "Release", destination: "macOS arm64"))
    }
}
