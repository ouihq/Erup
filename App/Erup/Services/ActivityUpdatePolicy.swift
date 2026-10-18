import Foundation

struct ActivityUpdatePolicy {
    static let minimumInterval: TimeInterval = 3

    /// Decides whether a new content state justifies a Live Activity update.
    /// Structural changes go through immediately; speed alone is rate limited.
    static func shouldUpdate(
        from old: ScooterActivityAttributes.ContentState?,
        to new: ScooterActivityAttributes.ContentState,
        secondsSinceLastUpdate: TimeInterval
    ) -> Bool {
        guard let old else { return true }
        if old.isConnected != new.isConnected
            || old.gearRaw != new.gearRaw
            || old.headlightOn != new.headlightOn
            || old.batteryPercent != new.batteryPercent {
            return secondsSinceLastUpdate >= 1
        }
        guard secondsSinceLastUpdate >= minimumInterval else { return false }
        return old.speedKmh != new.speedKmh
            || old.rangeKm != new.rangeKm
            || abs(old.tripKm - new.tripKm) >= 0.1
    }
}
