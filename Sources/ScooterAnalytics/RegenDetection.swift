import Foundation

/// When the motor counts as feeding energy back into the battery. The live dashboard, the ride recorder and the
/// ride detail all use this one rule, so the numbers agree everywhere.
public enum RegenDetection {
    /// While standing still a small negative current is not regeneration, for example when the lock holds the motor.
    public static let minimumSpeedKmh = 2.0
    /// Negative power below this many watts is measurement noise: the controller reports about +-0.1 A (+-4 W) at idle.
    public static let minimumWatts = 5.0

    public static func isRegen(powerWatts: Double, speedKmh: Double) -> Bool {
        speedKmh > minimumSpeedKmh && powerWatts <= -minimumWatts
    }

    /// The power coming back at this moment, or 0 when nothing is.
    public static func recoveredWatts(powerWatts: Double, speedKmh: Double) -> Double {
        isRegen(powerWatts: powerWatts, speedKmh: speedKmh) ? -powerWatts : 0
    }
}
