import Foundation

/// Persists only what the menu bar lets you choose (devices, channel, four sliders), so later
/// changes to the other code defaults in `DSPSettings` still take effect. Shared by the menu bar
/// and headless modes.
enum Preferences {
    private static var defaults: UserDefaults { .standard }

    private enum Key {
        static let gateThreshold = "gateThresholdDB"
        static let compressorThreshold = "compressorThresholdDB"
        static let compressorRatio = "compressorRatio"
        static let deEssThreshold = "deEssThresholdDB"
        /// Pre-1.1 expander threshold; read once as the gate threshold so a tuned value carries over.
        static let legacyExpansionThreshold = "expansionThresholdDB"
        static let inputChannel = "inputChannel"
        static let inputDevice = "inputDevice"
        static let outputDevice = "outputDevice"
    }

    static var settings: DSPSettings {
        get {
            var settings = DSPSettings()
            if let value = (defaults.object(forKey: Key.gateThreshold) ?? defaults.object(forKey: Key.legacyExpansionThreshold)) as? Float {
                settings.gateThresholdDB = value
            }
            if let value = defaults.object(forKey: Key.compressorThreshold) as? Float { settings.compressorThresholdDB = value }
            if let value = defaults.object(forKey: Key.compressorRatio) as? Float { settings.compressorRatio = value }
            if let value = defaults.object(forKey: Key.deEssThreshold) as? Float { settings.deEssThresholdDB = value }
            return settings
        }
        set {
            defaults.set(newValue.gateThresholdDB, forKey: Key.gateThreshold)
            defaults.set(newValue.compressorThresholdDB, forKey: Key.compressorThreshold)
            defaults.set(newValue.compressorRatio, forKey: Key.compressorRatio)
            defaults.set(newValue.deEssThresholdDB, forKey: Key.deEssThreshold)
            defaults.removeObject(forKey: Key.legacyExpansionThreshold)
            defaults.removeObject(forKey: "compressionHeadroomDB")
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
