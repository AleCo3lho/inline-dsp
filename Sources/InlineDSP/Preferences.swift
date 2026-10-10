import Foundation

/// Persists only what the menu bar lets you choose (devices, channel, three sliders), so later
/// changes to the other code defaults in `DSPSettings` still take effect. Shared by the menu bar
/// and headless modes.
enum Preferences {
    private static var defaults: UserDefaults { .standard }

    private enum Key {
        static let expansionThreshold = "expansionThresholdDB"
        static let compressionHeadroom = "compressionHeadroomDB"
        static let deEssThreshold = "deEssThresholdDB"
        static let inputChannel = "inputChannel"
        static let inputDevice = "inputDevice"
        static let outputDevice = "outputDevice"
    }

    static var settings: DSPSettings {
        get {
            var settings = DSPSettings()
            if let value = defaults.object(forKey: Key.expansionThreshold) as? Float { settings.expansionThresholdDB = value }
            if let value = defaults.object(forKey: Key.compressionHeadroom) as? Float { settings.compressionHeadroomDB = value }
            if let value = defaults.object(forKey: Key.deEssThreshold) as? Float { settings.deEssThresholdDB = value }
            return settings
        }
        set {
            defaults.set(newValue.expansionThresholdDB, forKey: Key.expansionThreshold)
            defaults.set(newValue.compressionHeadroomDB, forKey: Key.compressionHeadroom)
            defaults.set(newValue.deEssThresholdDB, forKey: Key.deEssThreshold)
        }
    }

    /// Device selections as UIDs (from the pickers) or names; nil until one is chosen.
    static var inputDevice: String? {
        get { defaults.string(forKey: Key.inputDevice) }
        set { defaults.set(newValue, forKey: Key.inputDevice) }
    }

    static var outputDevice: String? {
        get { defaults.string(forKey: Key.outputDevice) }
        set { defaults.set(newValue, forKey: Key.outputDevice) }
    }

    static var inputChannel: InputChannelSelection {
        get {
            guard let data = defaults.data(forKey: Key.inputChannel),
                  let selection = try? JSONDecoder().decode(InputChannelSelection.self, from: data) else { return .microphone }
            return selection
        }
        set {
            defaults.set(try? JSONEncoder().encode(newValue), forKey: Key.inputChannel)
        }
    }
}
