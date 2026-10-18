import Foundation

enum FeatureFlags {
    /// Confirmed on a real scooter: a set lock bit means unlocked. The flag exists only to flip that if a model differs.
    static let lockFlagMeansLockedKey = "flag.lockFlagMeansLocked"

    static var lockFlagMeansLocked: Bool {
        UserDefaults.standard.bool(forKey: lockFlagMeansLockedKey)
    }
}
