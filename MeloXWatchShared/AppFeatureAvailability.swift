import Foundation

enum AppFeatureAvailability {
    /// App Store Connect builds use the `com.aritxonly.MeloX` bundle identifier
    /// family. Legacy/self-signed builds use `com.aritxonly.legacy.MeloX` and keep downloads.
    static let downloads: Bool = {
        #if DEBUG
            true
        #else
            guard let bundleIdentifier = Bundle.main.bundleIdentifier else {
                return false
            }
            return !bundleIdentifier.hasPrefix("com.aritxonly.MeloX")
        #endif
    }()
}
