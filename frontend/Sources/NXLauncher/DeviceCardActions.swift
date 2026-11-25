import AppKit
import NXModel

enum XcodeLauncher {
    @MainActor static func open() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.dt.Xcode") { NSWorkspace.shared.open(url) }
    }
}

extension DeviceStore {
    func stepSigningTeam(_ by: Int, options: [(value: String, label: String)]) {
        guard !options.isEmpty else { return }
        let index = options.firstIndex { $0.value == signingTeam } ?? 0
        signingTeam = options[(index + by + options.count) % options.count].value
    }
}
