import Foundation

enum FeatureFlags {
    /// Confirmed on a real scooter: a set lock bit means unlocked. The flag exists only to flip that if a model differs.
    static let lockFlagMeansLockedKey = "flag.lockFlagMeansLocked"

    /// For debugging: stops the app from sending anything but keep-alives and the commands the rider asks for.
    /// If the stream stalls less with this on, the automatic reads (settings and lock state) are what triggers it.
    static let pauseAutomaticReadsKey = "debug.pauseAutomaticReads"

    static var pauseAutomaticReads: Bool {
        UserDefaults.standard.bool(forKey: pauseAutomaticReadsKey)
    }

    static var lockFlagMeansLocked: Bool {
        UserDefaults.standard.bool(forKey: lockFlagMeansLockedKey)
    }
}
