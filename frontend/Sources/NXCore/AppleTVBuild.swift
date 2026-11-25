import Foundation

package enum AppleTVBuild {
    package static let environment = ["DM_TVOS": "1"]
    package static let settingsDestination = "Library/Caches/env.txt"
    package static let appName = "DmIOS.app"
    private static let schemeSuffix = ".xcscheme"
    private static let settingsLinePattern = #"^[A-Za-z_][A-Za-z0-9_]*=.*$"#

    package static func workspace(workDir: String) -> String { workDir + "/AppleTV.xcworkspace" }

    package static func schemesFolder(workDir: String) -> String { workDir + "/xcode/DmIOS.xcodeproj/xcshareddata/xcschemes" }

    package static func appPath(workDir: String) -> String {
        workDir + "/xcode-derived-data/Build/Products/Release-appletvos/" + appName
    }

    package static func scriptArguments(workDir: String, team: String) -> [String] {
        ["--romfs", "bundle", "--no-show-fps", "--prepare-xcode", "--xcode-workspace", workspace(workDir: workDir), "--team-id", team]
    }

    package static func scheme(amongFiles names: [String]) -> String? {
        names.filter { $0.hasSuffix(schemeSuffix) }.sorted().first.map { String($0.dropLast(schemeSuffix.count)) }
    }

    package static func buildCommand(xcrun: String, workDir: String, scheme: String, device: String, team: String) -> [String] {
        [xcrun, "xcodebuild", "-workspace", workspace(workDir: workDir), "-scheme", scheme, "-configuration", "Release",
         "-destination", "platform=tvOS,id=\(device)", "-allowProvisioningUpdates",
         "DEVELOPMENT_TEAM=\(team)", "CODE_SIGN_STYLE=Automatic", "build"]
    }

    package static func settingsPushCommand(xcrun: String, device: String, bundleID: String, source: String) -> [String] {
        [xcrun, "devicectl", "device", "copy", "to", "--device", device, "--domain-type", "appDataContainer",
         "--domain-identifier", bundleID, "--source", source, "--destination", settingsDestination]
    }

    package static func sdkCommand(xcrun: String) -> [String] {
        [xcrun, "--sdk", "appletvos", "--show-sdk-version"]
    }

    private static func trimmedLines(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func isSetting(_ line: String) -> Bool {
        line.range(of: settingsLinePattern, options: .regularExpression) != nil
    }

    package static func settingsLines(_ text: String) -> [String] {
        trimmedLines(text).filter(isSetting)
    }

    package static func ignoredSettingsLines(_ text: String) -> [String] {
        trimmedLines(text).filter { !$0.isEmpty && !$0.hasPrefix("#") && !isSetting($0) }
    }

    package static func settingsFile(_ text: String) -> String {
        let lines = settingsLines(text)
        return lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
    }

    package static func bundleID(infoPlist data: Data) -> String? {
        let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
        guard let id = plist?["CFBundleIdentifier"] as? String, !id.isEmpty else { return nil }
        return id
    }

    package static func sdkAvailable(xcrun: String, runner: ProcessRunner) -> Bool {
        let command = sdkCommand(xcrun: xcrun)
        return runner.capture(ProcessLaunch(executable: command[0], arguments: Array(command.dropFirst()), timeout: 20)).ok
    }
}
