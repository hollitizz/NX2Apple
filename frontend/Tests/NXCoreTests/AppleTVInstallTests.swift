import XCTest
@testable import NXCore

final class AppleTVInstallTests: XCTestCase {
    private var workDir: URL!
    private let fake = FakeProcessRunner()
    private let bundleID = "org.nxnative.0100000000001000.ABCDE12345"

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory.appendingPathComponent("tv-install-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workDir)
    }

    private func preparePrepared(withApp: Bool = true) throws {
        let schemes = URL(fileURLWithPath: AppleTVBuild.schemesFolder(workDir: workDir.path))
        try FileManager.default.createDirectory(at: schemes, withIntermediateDirectories: true)
        try Data().write(to: schemes.appendingPathComponent("Galaxy (0100000000001000).xcscheme"))
        guard withApp else { return }
        let app = URL(fileURLWithPath: AppleTVBuild.appPath(workDir: workDir.path))
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let plist = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": bundleID], format: .xml, options: 0)
        try plist.write(to: app.appendingPathComponent("Info.plist"))
    }

    private func installer() -> ShellInstaller {
        var installer = ShellInstaller(xcrun: "/fake/xcrun", repo: "/tmp/repo", python: "/usr/bin/python3", root: "/tmp/shell",
                                       device: "TV-UDID", team: "ABCDE12345")
        installer.deviceName = "Living Room"
        installer.runner = fake
        return installer
    }

    func testSignsInstallsAndPushesTheSettings() throws {
        try preparePrepared()
        let result = installer().installOnAppleTV(workDir: workDir.path, settings: "DM_OPMODE=1\n# note\n")
        XCTAssertTrue(result.ok, result.message)
        XCTAssertEqual(result.bundleID, bundleID)
        XCTAssertEqual(fake.launches.count, 3)
        let build = AppleTVBuild.buildCommand(xcrun: "/fake/xcrun", workDir: workDir.path, scheme: "Galaxy (0100000000001000)",
                                              device: "TV-UDID", team: "ABCDE12345")
        XCTAssertEqual(fake.launches[0].arguments, Array(build.dropFirst()))
        XCTAssertEqual(fake.launches[1].arguments, ["devicectl", "device", "install", "app", "--device", "TV-UDID",
                                                    AppleTVBuild.appPath(workDir: workDir.path)])
        let push = fake.launches[2].arguments
        XCTAssertEqual(push.last, "Library/Caches/env.txt")
        XCTAssertEqual(push[push.firstIndex(of: "--domain-identifier")! + 1], bundleID)
    }

    func testEmptySettingsClearTheEnvFileOnTheAppleTV() throws {
        try preparePrepared()
        var pushed: [String] = []
        fake.onStreamLines = { launch in
            guard launch.arguments.last == AppleTVBuild.settingsDestination,
                  let i = launch.arguments.firstIndex(of: "--source") else { return }
            pushed.append((try? String(contentsOfFile: launch.arguments[i + 1], encoding: .utf8)) ?? "unreadable")
        }
        let result = installer().installOnAppleTV(workDir: workDir.path, settings: "  \n")
        XCTAssertTrue(result.ok)
        XCTAssertEqual(fake.launches.count, 3)
        XCTAssertEqual(pushed, [""], "an empty env.txt replaces the one an earlier install left")
    }

    func testIgnoredSettingsLinesGoToTheLog() throws {
        try preparePrepared()
        var logged = ""
        var installer = installer()
        installer.log = { logged += $0 }
        _ = installer.installOnAppleTV(workDir: workDir.path, settings: "DM_OPMODE=1\nnot a setting\n# a note\n")
        XCTAssertTrue(logged.contains("not a setting"), logged)
        XCTAssertFalse(logged.contains("a note"), "a comment is not an ignored line")
    }

    func testStageIDsAreDistinct() {
        let ids = [ShellInstaller.projectStageID, ShellInstaller.signStageID, ShellInstaller.installStageID, ShellInstaller.copyStageID,
                   ShellInstaller.checkStageID, ShellInstaller.exportBuildStageID, ShellInstaller.exportPackStageID,
                   ShellInstaller.appleTVSettingsStageID]
        XCTAssertEqual(Set(ids).count, ids.count, "\(ids)")
    }

    func testAMissingProjectStopsBeforeXcode() {
        let result = installer().installOnAppleTV(workDir: workDir.path, settings: "")
        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.step, .sign)
        XCTAssertTrue(fake.launches.isEmpty)
    }

    func testAFailedSigningSaysWhereTheWorkspaceIs() throws {
        try preparePrepared()
        fake.lines = ["error: No Account for Team \"ABCDE12345\""]
        fake.lineStatus = 65
        let result = installer().installOnAppleTV(workDir: workDir.path, settings: "DM_OPMODE=1")
        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.step, .sign)
        XCTAssertTrue(result.message.contains("No Account for Team"), result.message)
        XCTAssertTrue(result.message.contains(AppleTVBuild.workspace(workDir: workDir.path)), result.message)
        XCTAssertEqual(fake.launches.count, 1)
    }

    func testABuildWithoutAnAppStopsBeforeTheInstall() throws {
        try preparePrepared(withApp: false)
        let result = installer().installOnAppleTV(workDir: workDir.path, settings: "")
        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.step, .install)
        XCTAssertEqual(fake.launches.count, 1)
    }
}
