import Foundation

extension ShellInstaller {
    func developerModeSignFailure(_ built: ToolResult, stageName: String) -> Outcome? {
        guard let devModeLine = BuildFailureClassifier.developerModeLine(in: built.output, deviceID: device) else { return nil }
        end(Self.signStageID, stageName, ok: false, detail: devModeLine)
        return Outcome(ok: false, message: fmt("dev.signFailed", devModeLine), step: .sign, failure: .developerMode)
    }

    func installFailure(_ installed: ToolResult, stageName: String) -> Outcome {
        let devModeLine = BuildFailureClassifier.developerModeLine(in: installed.output, deviceID: device)
        let why = devModeLine ?? installed.lastError ?? fmt("msg.exitCode", installed.status)
        end(Self.installStageID, stageName, ok: false, detail: why)
        return Outcome(ok: false, message: fmt("dev.installFailed", why), step: .install, failure: devModeLine == nil ? nil : .developerMode)
    }
}
