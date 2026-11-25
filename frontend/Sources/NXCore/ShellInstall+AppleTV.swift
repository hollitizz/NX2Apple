import Foundation

extension ShellInstaller {
    package static let appleTVSettingsStageID = 1020

    private func appleTVScheme(workDir: String) -> String? {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: AppleTVBuild.schemesFolder(workDir: workDir))) ?? []
        return AppleTVBuild.scheme(amongFiles: names)
    }

    private func appleTVSignFailure(_ built: ToolResult, workDir: String, name: String) -> Outcome {
        if let devMode = developerModeSignFailure(built, stageName: name) { return devMode }
        let why = built.lastError ?? fmt("msg.exitCode", built.status)
        end(Self.signStageID, name, ok: false, detail: why)
        let hint = fmt("tv.signHint", AppleTVBuild.workspace(workDir: workDir))
        return Outcome(ok: false, message: fmt("dev.signFailed", why) + "\n" + hint, step: .sign)
    }

    private func buildForAppleTV(workDir: String, scheme: String) -> Outcome? {
        let name = fmt("dev.signStage", deviceName)
        begin(Self.signStageID, name)
        let command = AppleTVBuild.buildCommand(xcrun: xcrun, workDir: workDir, scheme: scheme, device: device, team: team)
        let built = run(command, env: nil, label: name, stageID: Self.signStageID, step: BuildProgress.xcodeStep)
        guard built.status == 0 else { return appleTVSignFailure(built, workDir: workDir, name: name) }
        end(Self.signStageID, name, ok: true)
        return nil
    }

    private func installAppleTVApp(_ app: String) -> Outcome? {
        let name = fmt("dev.installStage", deviceName)
        begin(Self.installStageID, name)
        let installed = run(ShellInstall.installCommand(xcrun: xcrun, device: device, app: app), env: nil, label: name,
                            stageID: Self.installStageID, step: BuildProgress.installStep)
        guard installed.status == 0 else { return installFailure(installed, stageName: name) }
        end(Self.installStageID, name, ok: true)
        return nil
    }

    private func writeAppleTVSettings(_ file: String) -> URL? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("nx2apple-tv-env-\(UUID().uuidString).txt")
        do {
            try file.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            log("settings: \(error.localizedDescription)\n")
            return nil
        }
    }

    private func logIgnoredAppleTVSettings(_ settings: String) {
        for line in AppleTVBuild.ignoredSettingsLines(settings) { log("settings: ignored, not KEY=VALUE: \(line)\n") }
    }

    private func pushAppleTVSettings(_ settings: String, bundleID: String) -> Outcome? {
        logIgnoredAppleTVSettings(settings)
        let file = AppleTVBuild.settingsFile(settings)
        let name = t("tv.settingsStage")
        begin(Self.appleTVSettingsStageID, name)
        guard let source = writeAppleTVSettings(file) else {
            end(Self.appleTVSettingsStageID, name, ok: false)
            return Outcome(ok: false, message: t("tv.settingsFailed"))
        }
        defer { try? FileManager.default.removeItem(at: source) }
        let command = AppleTVBuild.settingsPushCommand(xcrun: xcrun, device: device, bundleID: bundleID, source: source.path)
        let pushed = run(command, env: nil, label: name, step: { _ in nil })
        let why = pushed.lastError ?? fmt("msg.exitCode", pushed.status)
        end(Self.appleTVSettingsStageID, name, ok: pushed.status == 0, detail: pushed.status == 0 ? "" : why)
        return pushed.status == 0 ? nil : Outcome(ok: false, message: t("tv.settingsFailed") + "\n" + why)
    }

    private func appleTVBundleID(app: String) -> String? {
        guard let data = FileManager.default.contents(atPath: app + "/Info.plist") else { return nil }
        return AppleTVBuild.bundleID(infoPlist: data)
    }

    package func installOnAppleTV(workDir: String, settings: String) -> Outcome {
        guard let scheme = appleTVScheme(workDir: workDir) else {
            return Outcome(ok: false, message: fmt("tv.noProject", AppleTVBuild.schemesFolder(workDir: workDir)), step: .sign)
        }
        if let failed = buildForAppleTV(workDir: workDir, scheme: scheme) { return failed }
        if waitCancelled() { return Outcome(ok: false, message: t("msg.stopped")) }
        let app = AppleTVBuild.appPath(workDir: workDir)
        guard let bundleID = appleTVBundleID(app: app) else {
            return Outcome(ok: false, message: fmt("dev.noProject", app), step: .install)
        }
        if let failed = installAppleTVApp(app) { return failed }
        if waitCancelled() { return Outcome(ok: false, message: t("msg.stopped")) }
        if let failed = pushAppleTVSettings(settings, bundleID: bundleID) { return failed }
        return Outcome(ok: true, message: fmt("dev.installed", deviceName), appPath: app, bundleID: bundleID)
    }
}
