import XCTest
@testable import NXCore

final class AppleTVBuildTests: XCTestCase {
    private let workDir = "/work/0100000000001000_build"

    private func device(platform: String, udid: String, name: String, reality: String = "physical") -> [String: Any] {
        [
            "hardwareProperties": ["reality": reality, "platform": platform, "udid": udid, "marketingName": name + " model"],
            "deviceProperties": ["name": name, "osVersionNumber": "27.3"],
            "connectionProperties": ["pairingState": "paired", "transportType": "localNetwork"],
            "properties": [
                "hardware": ["platform": platform, "udid": udid],
                "software": ["osVersionNumber": ["stringValue": "27.3"]],
                "connection": ["pairingState": "paired", "transportType": "localNetwork"],
            ],
        ]
    }

    private func listing() -> Data {
        let devices = [
            device(platform: "tvOS", udid: "TV-UDID", name: "Living Room"),
            device(platform: "iOS", udid: "PHONE-UDID", name: "Jo's iPhone"),
            device(platform: "tvOS", udid: "SIM-TV", name: "Simulated TV", reality: "simulated"),
        ]
        return try! JSONSerialization.data(withJSONObject: ["result": ["devices": devices]])
    }

    func testParseDevicesKeepsOnlyTheAskedPlatform() {
        XCTAssertEqual(DeviceTools.parseDevices(listing(), platform: .tvOS).map(\.id), ["TV-UDID"])
        XCTAssertEqual(DeviceTools.parseDevices(listing()).map(\.id), ["PHONE-UDID"])
        let tv = DeviceTools.parseDevices(listing(), platform: .tvOS).first
        XCTAssertEqual(tv?.name, "Living Room")
        XCTAssertEqual(tv?.model, "Living Room model")
        XCTAssertEqual(tv?.overNetwork, true)
    }

    func testDevicesForTheAppleTVReadTheSameDevicectlListing() {
        let fake = FakeProcessRunner()
        let data = listing()
        fake.answer = { launch in
            if let i = launch.arguments.firstIndex(of: "--json-output") { try? data.write(to: URL(fileURLWithPath: launch.arguments[i + 1])) }
            return ProcessResult()
        }
        let tvs = DeviceTools.devices(xcrun: "/fake/xcrun", runner: fake, platform: .tvOS)
        XCTAssertEqual(tvs.map(\.id), ["TV-UDID"])
        XCTAssertEqual(Array(fake.launches[0].arguments.prefix(3)), ["devicectl", "list", "devices"])
    }

    func testScriptArgumentsBundleTheGameAndPrepareTheXcodeProject() {
        XCTAssertEqual(AppleTVBuild.scriptArguments(workDir: workDir, team: "ABCDE12345"), [
            "--romfs", "bundle", "--no-show-fps", "--prepare-xcode", "--xcode-workspace", workDir + "/AppleTV.xcworkspace",
            "--team-id", "ABCDE12345",
        ])
        XCTAssertEqual(AppleTVBuild.environment, ["DM_TVOS": "1"])
    }

    func testBuildCommandSignsForTheChosenAppleTV() {
        let command = AppleTVBuild.buildCommand(xcrun: "/usr/bin/xcrun", workDir: workDir, scheme: "Galaxy (0100000000001000)",
                                                device: "TV-UDID", team: "ABCDE12345")
        XCTAssertEqual(command, [
            "/usr/bin/xcrun", "xcodebuild", "-workspace", workDir + "/AppleTV.xcworkspace", "-scheme", "Galaxy (0100000000001000)",
            "-configuration", "Release", "-destination", "platform=tvOS,id=TV-UDID", "-allowProvisioningUpdates",
            "DEVELOPMENT_TEAM=ABCDE12345", "CODE_SIGN_STYLE=Automatic", "build",
        ])
    }

    func testSettingsPushCommandWritesEnvTxtInLibraryCaches() {
        XCTAssertEqual(AppleTVBuild.settingsPushCommand(xcrun: "xcrun", device: "TV-UDID", bundleID: "org.nxnative.x.T", source: "/tmp/env.txt"), [
            "xcrun", "devicectl", "device", "copy", "to", "--device", "TV-UDID", "--domain-type", "appDataContainer",
            "--domain-identifier", "org.nxnative.x.T", "--source", "/tmp/env.txt", "--destination", "Library/Caches/env.txt",
        ])
    }

    func testSchemeIsTheSchemeFileOfThePreparedProject() {
        XCTAssertEqual(AppleTVBuild.scheme(amongFiles: [".DS_Store", "Galaxy (0100000000001000).xcscheme"]), "Galaxy (0100000000001000)")
        XCTAssertNil(AppleTVBuild.scheme(amongFiles: ["xcschememanagement.plist"]))
        XCTAssertNil(AppleTVBuild.scheme(amongFiles: []))
    }

    func testAppPathIsTheReleaseAppleTVProduct() {
        XCTAssertEqual(AppleTVBuild.appPath(workDir: workDir), workDir + "/xcode-derived-data/Build/Products/Release-appletvos/DmIOS.app")
    }

    func testSettingsKeepOnlyKeyValueLines() {
        let text = "  DM_OPMODE=1 \n\n# a note\nDM_MOTION_SCALE=1.18,1.17,1\nnot a setting\n=empty\nDM_SIX_DELAY=auto"
        XCTAssertEqual(AppleTVBuild.settingsLines(text), ["DM_OPMODE=1", "DM_MOTION_SCALE=1.18,1.17,1", "DM_SIX_DELAY=auto"])
        XCTAssertEqual(AppleTVBuild.settingsFile(text), "DM_OPMODE=1\nDM_MOTION_SCALE=1.18,1.17,1\nDM_SIX_DELAY=auto\n")
        XCTAssertEqual(AppleTVBuild.settingsFile(" \n# nothing\n"), "")
    }

    func testIgnoredSettingsLinesAreTheNonCommentLinesThatAreNoSetting() {
        let text = "DM_OPMODE=1\n\n# a note\nnot a setting\n=empty\n  \n"
        XCTAssertEqual(AppleTVBuild.ignoredSettingsLines(text), ["not a setting", "=empty"])
        XCTAssertEqual(AppleTVBuild.ignoredSettingsLines("DM_OPMODE=1"), [])
    }

    func testBundleIDComesFromTheBuiltAppsInfoPlist() throws {
        let plist = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "org.nxnative.0100000000001000.ABCDE12345"],
                                                       format: .xml, options: 0)
        XCTAssertEqual(AppleTVBuild.bundleID(infoPlist: plist), "org.nxnative.0100000000001000.ABCDE12345")
        XCTAssertNil(AppleTVBuild.bundleID(infoPlist: Data("not a plist".utf8)))
    }

    func testSDKCheckAsksXcrunForTheAppleTVSDK() {
        let fake = FakeProcessRunner()
        XCTAssertTrue(AppleTVBuild.sdkAvailable(xcrun: "/fake/xcrun", runner: fake))
        XCTAssertEqual(fake.launches.first?.arguments, ["--sdk", "appletvos", "--show-sdk-version"])
        fake.answer = { _ in ProcessResult(status: 1) }
        XCTAssertFalse(AppleTVBuild.sdkAvailable(xcrun: "/fake/xcrun", runner: fake))
    }

    func testPlanPreparesXcodeThenSignsAndInstallsOnTheAppleTV() {
        let input = BuildPlanInput(upstream: .nxnative, target: BuildTarget.tvos, deviceName: "Living Room")
        let stages = BuildPlan.initialStages(for: input)
        XCTAssertEqual(stages.map(\.name), ["extract", "rewrite", "shader split", "iOS shaders", "prepare Xcode", "dev.signStage", "dev.installStage"])
        XCTAssertEqual(stages.suffix(2).map(\.id), [ShellInstaller.signStageID, ShellInstaller.installStageID])
        XCTAssertEqual(stages.suffix(2).map(\.nameArgument), ["Living Room", "Living Room"])
    }

    func testSavedTargetKeepsTheAppleTVAndTheQueueDoesNot() {
        let defaults = TestDefaults.make("apple-tv-target")
        defaults.set(BuildTarget.tvos, forKey: "buildTarget")
        XCTAssertEqual(BuildTarget.saved(defaults), BuildTarget.tvos)
        XCTAssertEqual(defaults.string(forKey: "buildTarget"), BuildTarget.tvos)
        XCTAssertEqual(BuildTarget.normalized(BuildTarget.tvos), BuildTarget.ios)
    }
}
