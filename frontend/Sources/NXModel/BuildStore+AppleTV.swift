import Foundation
import NXCore

extension BuildStore {
    nonisolated package static let appleTVSettingsKeyPrefix = "appleTVSettings."

    package func appleTVSettings(forGame key: String) -> String {
        defaults.string(forKey: Self.appleTVSettingsKeyPrefix + key) ?? ""
    }

    package func setAppleTVSettings(_ text: String, forGame key: String) {
        guard !key.isEmpty else { return }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            defaults.removeObject(forKey: Self.appleTVSettingsKeyPrefix + key)
        } else {
            defaults.set(text, forKey: Self.appleTVSettingsKeyPrefix + key)
        }
    }

    package var appleTVQueueBlock: String? { target == BuildTarget.tvos ? t("tv.queueBlocked") : nil }

    private var appleTVDeviceProblemKey: String? {
        guard let device = devices.appleTVs.first(where: { $0.id == devices.appleTVDevice }) else {
            return devices.appleTVs.isEmpty ? "tv.pairDevice" : "tv.needsDevice"
        }
        return device.reachable ? nil : "tv.asleep"
    }

    package var appleTVProblemKey: String? {
        if buildUpstream != .nxnative { return "tv.nxnativeOnly" }
        if devices.tvOSSDKReady == false { return "tv.noSDK" }
        if let deviceProblem = appleTVDeviceProblemKey { return deviceProblem }
        return devices.signingTeam.isEmpty ? "tv.needsTeam" : nil
    }

    package func appleTVProblem() -> String? { appleTVProblemKey.map(t) }

    private func beginAppleTVCheck() {
        buildingGame = true
        runningTarget = target
        beginOperation(.building, game: gameName, titleID: gameTitleID, destination: .target)
        stopping = false
        stoppedByPlayer = false
        installPhaseActive = true
        running = true
        done = false
        doneNote = ""
        failure = nil
        stages = []
    }

    private func finishAppleTVCheck() {
        installPhaseActive = false
        running = false
        if stopping {
            stopping = false
            doneNote = t("msg.stopped")
            return
        }
        if let why = appleTVProblem() {
            doneNote = why
            return
        }
        appleTVDeviceChecked = true
        runBuild()
        appleTVDeviceChecked = false
    }

    private func verifyAppleTVDevice() {
        beginAppleTVCheck()
        let refresh = devices.refreshAppleTVs()
        Task { @MainActor in
            await refresh.value
            self.finishAppleTVCheck()
        }
    }

    func deferredForAppleTVCheck() -> Bool {
        guard target == BuildTarget.tvos else { return false }
        if appleTVDeviceChecked {
            appleTVDeviceChecked = false
            return false
        }
        verifyAppleTVDevice()
        return true
    }

    var appleTVEnvironment: [String: String] { target == BuildTarget.tvos ? AppleTVBuild.environment : [:] }

    func deviceScriptArguments(workDir: String) -> [String] {
        if target == BuildTarget.tvos { return AppleTVBuild.scriptArguments(workDir: workDir, team: devices.signingTeam) }
        return ShellInstall.buildArguments(workDir: workDir, team: exportsShell ? "" : devices.signingTeam)
    }

    private func beginAppleTVInstall(device: String) {
        buildingGame = true
        beginOperation(.installing, game: gameName, titleID: gameTitleID, destination: .device(devices.deviceName(device)))
        stopping = false
        installCancel.set(false)
        installPhaseActive = true
        running = true
        installedOn = ""
        installedAppPath = ""
        archivePath = ""
    }

    private func noteAppleTVFailure(_ result: ShellInstaller.Outcome) {
        if let kind = result.failure {
            failure = BuildFailure(kind: kind, gameName: nil)
            return
        }
        guard let step = result.step else { return }
        noteInstallFailure(step, error: result.message)
        if failure == nil, step == .sign {
            failure = BuildFailure(kind: .appleTVSigning, gameName: nil, detail: AppleTVBuild.workspace(workDir: effectiveWorkDir))
        }
    }

    private func failAppleTVInstall(_ result: ShellInstaller.Outcome) {
        finishInstall(result.message)
        noteAppleTVFailure(result)
        setInstallRecovery(.resumeClosure { [weak self] in self?.installOnAppleTV() })
    }

    private func finishAppleTVInstall(_ result: ShellInstaller.Outcome) {
        installPhaseActive = false
        if stopping {
            stopping = false
            running = false
            failure = nil
            resetProgress()
            doneNote = t("msg.stopped")
            cleanupStaging()
            return
        }
        guard result.ok else { return failAppleTVInstall(result) }
        finishInstall(nil, note: result.message)
    }

    func finishAppleTVScript() {
        fastRefreshExternalImgPath = nil
        installOnAppleTV()
    }

    func installOnAppleTV() {
        let device = devices.appleTVDevice
        let settings = appleTVSettings(forGame: buildKey)
        let workDir = effectiveWorkDir
        let cancel = installCancel
        var installer = makeInstaller(device: device)
        installer.waitCancelled = { cancel.value }
        beginAppleTVInstall(device: device)
        DispatchQueue.global(qos: .userInitiated).async {
            let result = installer.installOnAppleTV(workDir: workDir, settings: settings)
            hop { self.finishAppleTVInstall(result) }
        }
    }
}
