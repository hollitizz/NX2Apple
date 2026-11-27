import XCTest
@testable import NXModel
@testable import NXCore

@MainActor final class AppleTVBuildStoreTests: XCTestCase {
    private final class FakeRepo: RepoLocation {
        var path: String
        var isRepo = true
        var isGit = true
        init(path: String) { self.path = path }
    }

    private final class FakeDeps: DependencyInstalling {
        var pythonPath = "/usr/bin/python3"
        var dotnetPath = "/usr/bin/true"
        var checked = true
        var allPresent = true
        var deps: [Dep] = []
        func isInstalling(_ id: String) -> Bool { false }
        func install(_ dep: Dep) -> Task<Void, Never> { Task {} }
    }

    private final class FakeEngine: EngineSyncing {
        func syncEngine(then: ((Bool) -> Void)?) -> Task<Void, Never> { then?(true); return Task {} }
    }

    private final class ScriptRunner: ProcessRunner, @unchecked Sendable {
        private let lock = NSLock()
        private var started: [ProcessLaunch] = []
        private var streamed: [ProcessLaunch] = []
        var exitStatus: Int32 = 1
        var onStart: ((ProcessLaunch) -> Void)?
        var toolStatus: (ProcessLaunch) -> Int32 = { _ in 0 }
        var toolLines: (ProcessLaunch) -> [String] = { _ in [] }

        var scriptLaunches: [ProcessLaunch] { lock.lock(); defer { lock.unlock() }; return started }
        var toolLaunches: [ProcessLaunch] { lock.lock(); defer { lock.unlock() }; return streamed }

        func capture(_ launch: ProcessLaunch) -> ProcessResult { ProcessResult() }
        func stream(_ launch: ProcessLaunch, line: @escaping (String) -> Void) -> Bool { true }
        func streamLines(_ launch: ProcessLaunch, started: @escaping (RunningProcess) -> Void, line: @escaping (String) -> Void) -> ProcessResult {
            lock.lock(); streamed.append(launch); lock.unlock()
            started(FakeRunningProcess())
            toolLines(launch).forEach(line)
            return ProcessResult(status: toolStatus(launch))
        }
        func start(_ launch: ProcessLaunch, onOutput: @escaping (Data) -> Void, onExit: @escaping (Int32) -> Void) throws -> RunningProcess {
            lock.lock(); started.append(launch); lock.unlock()
            onStart?(launch)
            onExit(exitStatus)
            return FakeRunningProcess()
        }
    }

    private final class AppleTVList: @unchecked Sendable {
        private let lock = NSLock()
        private var listed: [AppleDevice]
        init(_ listed: [AppleDevice]) { self.listed = listed }
        var devices: [AppleDevice] {
            get { lock.lock(); defer { lock.unlock() }; return listed }
            set { lock.lock(); listed = newValue; lock.unlock() }
        }
    }

    private final class GatedAppleTVList: @unchecked Sendable {
        private let lock = NSLock()
        private var calls = 0
        private var gates: [Int: DispatchSemaphore] = [:]
        private var answers: [Int: [AppleDevice]] = [:]
        private let first: [AppleDevice]
        init(first: [AppleDevice], gated: [Int]) {
            self.first = first
            for index in gated { gates[index] = DispatchSemaphore(value: 0) }
        }
        var callCount: Int { lock.lock(); defer { lock.unlock() }; return calls }
        func release(_ index: Int, with devices: [AppleDevice]) {
            lock.lock(); answers[index] = devices; let gate = gates[index]; lock.unlock()
            gate?.signal()
        }
        func list() -> [AppleDevice] {
            lock.lock(); let index = calls; calls += 1; let gate = gates[index]; lock.unlock()
            guard let gate else { return first }
            gate.wait()
            lock.lock(); defer { lock.unlock() }
            return answers[index] ?? first
        }
    }

    private let asleep = AppleDevice(id: "TV-UDID", name: "Living Room", model: "Apple TV 4K (3rd generation)", os: "27.3", reachable: false)
    private let appleTV = AppleDevice(id: "TV-UDID", name: "Living Room", model: "Apple TV 4K (3rd generation)", os: "27.3",
                                      reachable: true, transport: "localNetwork")
    private let team = SigningTeam(id: "ABCDE12345", identity: "Apple Development: Jo (ABCDE12345)")
    private var defaults: UserDefaults!
    private var temporary: URL!

    override func setUpWithError() throws {
        defaults = TestDefaults.make("apple-tv-build-store")
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent("tv-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporary)
    }

    private func makeRepo() throws -> String {
        let root = temporary.appendingPathComponent("repo")
        for rel in [EngineLayout.marker] + RepoLayout.requiredTools {
            let file = root.appendingPathComponent(rel)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("'--work-dir' '--romfs-from' '--from-seed'\n".utf8).write(to: file)
        }
        return root.path
    }

    private func drain(until done: () -> Bool) {
        let deadline = Date().addingTimeInterval(3)
        while !done() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    }

    private func makeDevices(runner: ProcessRunner, appleTVs: [AppleDevice], sdkReady: Bool = true) -> DeviceStore {
        makeDevices(runner: runner, list: AppleTVList(appleTVs), sdkReady: sdkReady)
    }

    private func makeDevices(runner: ProcessRunner, list: AppleTVList, sdkReady: Bool = true) -> DeviceStore {
        let teams = [team]
        let store = DeviceStore(runner: runner, xcrun: "/usr/bin/true", defaults: defaults, listDevices: { _ in [] },
                                readTeams: { teams }, listAppleTVs: { _ in list.devices }, probeTVOSSDK: { _ in sdkReady })
        store.refreshAppleTVs()
        drain { store.appleTVsChecked }
        return store
    }

    private func makeBuild(runner: ScriptRunner, devices: DeviceStore) throws -> BuildStore {
        let build = BuildStore(localizer: Localizer(.en), runner: runner, repo: FakeRepo(path: try makeRepo()), deps: FakeDeps(),
                               engine: FakeEngine(), devices: devices, defaults: defaults)
        build.target = BuildTarget.tvos
        let base = temporary.appendingPathComponent("Game [0100000000001000].nsp")
        let keys = temporary.appendingPathComponent("prod.keys")
        try Data([0]).write(to: base)
        try Data([0]).write(to: keys)
        build.updateSlot("base") { $0.paths = [base.path] }
        build.updateSlot("keys") { $0.paths = [keys.path] }
        build.outDir = temporary.path
        return build
    }

    nonisolated private func value(after flag: String, in arguments: [String]) -> String? {
        arguments.firstIndex(of: flag).map { arguments[$0 + 1] }
    }

    nonisolated private func prepareXcodeOutput(workDir: String) {
        let schemes = URL(fileURLWithPath: AppleTVBuild.schemesFolder(workDir: workDir))
        try? FileManager.default.createDirectory(at: schemes, withIntermediateDirectories: true)
        try? Data().write(to: schemes.appendingPathComponent("Game (0100000000001000).xcscheme"))
        let app = URL(fileURLWithPath: AppleTVBuild.appPath(workDir: workDir))
        try? FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let plist = try? PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "org.nxnative.0100000000001000.ABCDE12345"],
                                                        format: .xml, options: 0)
        try? plist?.write(to: app.appendingPathComponent("Info.plist"))
    }

    func testRefreshPicksThePairedAppleTVAndTheStoreSaysWhatIsMissing() throws {
        let runner = ScriptRunner()
        XCTAssertEqual(try makeBuild(runner: runner, devices: makeDevices(runner: runner, appleTVs: [])).appleTVProblemKey, "tv.pairDevice")
        XCTAssertEqual(try makeBuild(runner: runner, devices: makeDevices(runner: runner, appleTVs: [appleTV], sdkReady: false)).appleTVProblemKey, "tv.noSDK")
        XCTAssertEqual(try makeBuild(runner: runner, devices: makeDevices(runner: runner, appleTVs: [asleep])).appleTVProblemKey, "tv.asleep")
        let ready = makeDevices(runner: runner, appleTVs: [appleTV])
        XCTAssertNil(try makeBuild(runner: runner, devices: ready).appleTVProblemKey)
        XCTAssertEqual(ready.appleTVDevice, "TV-UDID")
        XCTAssertEqual(ready.deviceName("TV-UDID"), "Living Room")
        XCTAssertEqual(defaults.string(forKey: DeviceStore.appleTVKey), "TV-UDID")
        XCTAssertEqual(ready.signingTeam, "ABCDE12345")
    }

    func testTheScriptBuildsAnAppleTVProject() throws {
        let runner = ScriptRunner()
        let build = try makeBuild(runner: runner, devices: makeDevices(runner: runner, appleTVs: [appleTV]))
        build.startBuild()
        drain { !build.running }
        let launch = try XCTUnwrap(runner.scriptLaunches.first)
        let workDir = try XCTUnwrap(value(after: "--work-dir", in: launch.arguments))
        XCTAssertEqual(launch.environment?["DM_TVOS"], "1")
        XCTAssertEqual(value(after: "--romfs", in: launch.arguments), "bundle")
        XCTAssertTrue(launch.arguments.contains("--prepare-xcode"))
        XCTAssertTrue(launch.arguments.contains("--no-show-fps"), "the frame-rate counter is off on the Apple TV")
        XCTAssertFalse(launch.arguments.contains("--show-fps"))
        XCTAssertEqual(value(after: "--xcode-workspace", in: launch.arguments), AppleTVBuild.workspace(workDir: workDir))
        XCTAssertEqual(value(after: "--team-id", in: launch.arguments), "ABCDE12345")
        XCTAssertFalse(launch.arguments.contains("--shell-framework"))
        XCTAssertTrue(runner.toolLaunches.isEmpty, "a failed script installs nothing")
    }

    func testWithoutAPairedAppleTVTheBuildDoesNotStart() throws {
        let runner = ScriptRunner()
        let build = try makeBuild(runner: runner, devices: makeDevices(runner: runner, appleTVs: []))
        build.startBuild()
        drain { !build.running && !build.doneNote.isEmpty }
        XCTAssertEqual(build.doneNote, build.t("tv.pairDevice"))
        XCTAssertTrue(runner.scriptLaunches.isEmpty)
    }

    func testAnAppleTVThatFellAsleepIsFoundBeforeTheBuild() throws {
        let runner = ScriptRunner()
        let list = AppleTVList([appleTV])
        let build = try makeBuild(runner: runner, devices: makeDevices(runner: runner, list: list))
        list.devices = [asleep]
        build.startBuild()
        drain { !build.running && !build.doneNote.isEmpty }
        XCTAssertEqual(build.doneNote, build.t("tv.asleep"))
        XCTAssertTrue(runner.scriptLaunches.isEmpty, "nothing is built for an Apple TV that cannot be reached")
    }

    func testThePreBuildCheckUsesTheNewestListingWhenARefreshOvertakesIt() throws {
        let runner = ScriptRunner()
        let list = GatedAppleTVList(first: [appleTV], gated: [1, 2])
        let teams = [team]
        let devices = DeviceStore(runner: runner, xcrun: "/usr/bin/true", defaults: defaults, listDevices: { _ in [] },
                                  readTeams: { teams }, listAppleTVs: { _ in list.list() }, probeTVOSSDK: { _ in true })
        devices.refreshAppleTVs()
        drain { devices.appleTVsChecked }
        let build = try makeBuild(runner: runner, devices: devices)
        build.startBuild()
        drain { list.callCount == 2 }
        devices.refreshAppleTVs()
        drain { list.callCount == 3 }
        list.release(1, with: [appleTV])
        drain { false }
        XCTAssertTrue(runner.scriptLaunches.isEmpty, "the check waits for the newer listing")
        list.release(2, with: [asleep])
        drain { !build.running && !build.doneNote.isEmpty }
        XCTAssertEqual(build.doneNote, build.t("tv.asleep"))
        XCTAssertTrue(runner.scriptLaunches.isEmpty)
    }

    func testAFirstSigningFailureOffersTheProjectAndARetryOfTheInstallOnly() throws {
        let runner = ScriptRunner()
        runner.exitStatus = 0
        runner.onStart = { [weak self] launch in
            guard let self, let workDir = self.value(after: "--work-dir", in: launch.arguments) else { return }
            self.prepareXcodeOutput(workDir: workDir)
        }
        runner.toolStatus = { $0.arguments.first == "xcodebuild" ? 65 : 0 }
        runner.toolLines = { $0.arguments.first == "xcodebuild" ? ["error: Failed to load credentials"] : [] }
        let build = try makeBuild(runner: runner, devices: makeDevices(runner: runner, appleTVs: [appleTV]))
        build.startBuild()
        drain { !build.running && build.failure != nil }
        XCTAssertEqual(build.failure?.kind, .appleTVSigning)
        let workDir = try XCTUnwrap(value(after: "--work-dir", in: runner.scriptLaunches[0].arguments))
        XCTAssertEqual(build.failure?.detail, AppleTVBuild.workspace(workDir: workDir))

        runner.toolStatus = { _ in 0 }
        runner.toolLines = { _ in [] }
        build.fixBuildFailure(.appleTVSigning)
        drain { build.done || (!build.running && build.failure != nil) }
        XCTAssertTrue(build.done, build.doneNote)
        XCTAssertEqual(runner.scriptLaunches.count, 1, "the retry does not build the game again")
        XCTAssertEqual(runner.toolLaunches.filter { $0.arguments.first == "xcodebuild" }.count, 2)
    }

    func testQueueEntryPointsAreClosedWhileTheBuildsPageIsOnAppleTV() throws {
        let runner = ScriptRunner()
        let build = try makeBuild(runner: runner, devices: makeDevices(runner: runner, appleTVs: [appleTV]))
        XCTAssertEqual(build.appleTVQueueBlock, build.t("tv.queueBlocked"))
        build.target = BuildTarget.ios
        XCTAssertNil(build.appleTVQueueBlock)
    }

    func testAQueuedEntryKeepsTheSavedAppleTVChoice() throws {
        let runner = ScriptRunner()
        let build = try makeBuild(runner: runner, devices: makeDevices(runner: runner, appleTVs: [appleTV]))
        let base = temporary.appendingPathComponent("Other [0100000000002000].nsp")
        try Data([0]).write(to: base)
        let entry = QueueEntry(titleID: "0100000000002000", name: "Other", target: BuildTarget.ios,
                               inputs: ["base": [base.path], "keys": [temporary.appendingPathComponent("prod.keys").path]],
                               outputDirectory: temporary.path, engineID: "main", exportIPA: true)
        _ = build.startQueued(entry)
        drain { !build.running && build.target == BuildTarget.tvos }
        let launch = try XCTUnwrap(runner.scriptLaunches.first)
        XCTAssertNil(launch.environment?["DM_TVOS"], "the entry builds for its own target")
        XCTAssertFalse(launch.arguments.contains("--prepare-xcode"))
        XCTAssertEqual(defaults.string(forKey: BuildStore.targetKey), BuildTarget.tvos, "the player's Apple TV choice stays saved")
        XCTAssertEqual(build.target, BuildTarget.tvos, "and is shown again once the entry is done")
    }

    func testASuccessfulScriptSignsInstallsAndPushesTheGamesSettings() throws {
        let runner = ScriptRunner()
        runner.exitStatus = 0
        runner.onStart = { [weak self] launch in
            guard let self, let workDir = self.value(after: "--work-dir", in: launch.arguments) else { return }
            self.prepareXcodeOutput(workDir: workDir)
        }
        let devices = makeDevices(runner: runner, appleTVs: [appleTV])
        devices.cancelWait()
        let build = try makeBuild(runner: runner, devices: devices)
        build.setAppleTVSettings("DM_OPMODE=1\n", forGame: build.buildKey)
        build.startBuild()
        drain { build.done || (!build.running && !build.doneNote.isEmpty) }
        XCTAssertTrue(build.done, build.doneNote)
        let tools = runner.toolLaunches.map(\.arguments)
        XCTAssertEqual(tools.count, 3)
        guard tools.count == 3 else { return }
        XCTAssertEqual(tools[0].first, "xcodebuild")
        XCTAssertEqual(value(after: "-destination", in: tools[0]), "platform=tvOS,id=TV-UDID")
        XCTAssertEqual(Array(tools[1].prefix(4)), ["devicectl", "device", "install", "app"])
        XCTAssertEqual(tools[2].last, AppleTVBuild.settingsDestination)
        XCTAssertTrue(build.installedAppPath.isEmpty, "an Apple TV app is not recorded as the iPhone's")
        XCTAssertEqual(build.doneNote, String(format: build.t("dev.installed"), "Living Room"))
    }

    func testSettingsAreKeptPerGame() throws {
        let build = BuildStore(localizer: Localizer(.en), runner: ScriptRunner(), repo: FakeRepo(path: temporary.path), deps: FakeDeps(),
                               engine: FakeEngine(), devices: DeviceStore(runner: ScriptRunner(), defaults: defaults), defaults: defaults)
        build.setAppleTVSettings("DM_OPMODE=1", forGame: "0100000000001000")
        XCTAssertEqual(build.appleTVSettings(forGame: "0100000000001000"), "DM_OPMODE=1")
        XCTAssertEqual(build.appleTVSettings(forGame: "0100000000002000"), "")
        build.setAppleTVSettings("  ", forGame: "0100000000001000")
        XCTAssertNil(defaults.string(forKey: BuildStore.appleTVSettingsKeyPrefix + "0100000000001000"))
    }
}
