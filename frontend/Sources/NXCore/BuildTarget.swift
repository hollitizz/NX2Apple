import Foundation

/// What a build makes. The launcher has three targets: a Mac app, the game's framework in the one shared app on an iPhone or
/// iPad, and a game's own app on an Apple TV. The target is stored as text in the settings and in the library.
package enum BuildTarget {
    package static let mac = "mac-app"
    package static let ios = "ios"
    package static let tvos = "tvos"

    /// Anything that is not the Mac app is the iPhone / iPad target. That covers a missing value, and the values older
    /// versions stored ("ios" for one IPA per game, "ios-shell" for the shared app).
    package static func normalized(_ value: String?) -> String { value == mac ? mac : ios }

    /// The saved choice. An old value is stored again in its new form.
    package static func saved(_ defaults: UserDefaults = .standard) -> String {
        let stored = defaults.string(forKey: "buildTarget")
        let value = stored == tvos ? tvos : normalized(stored)
        if stored != nil, stored != value { defaults.set(value, forKey: "buildTarget") }
        return value
    }
}
