import Foundation
import ScooterAnalytics

/// What Erup does when the scooter stops sending data while the Bluetooth link is still up.
///
/// In every mode the first step is the same: a short burst of keep-alives, which revives a stalled stream without
/// a reconnect. The modes differ in what happens when that does not help. A reconnect makes the scooter beep.
enum StallRecovery: String, CaseIterable, Identifiable, Sendable {
    case quick, patient, never

    static let storageKey = "connection.stallRecovery"
    static let defaultValue = StallRecovery.quick

    var id: Self { self }

    var title: String {
        switch self {
        case .quick: "Reconnect quickly"
        case .patient: "Wait longer"
        case .never: "Don't reconnect"
        }
    }

    var explanation: String {
        switch self {
        case .quick: "After a few keep-alives, reconnects once the scooter has been silent for about 6 seconds. Data returns soonest, but the scooter beeps at every reconnect."
        case .patient: "Reconnects only after about 15 seconds of silence. Fewer reconnects and beeps if the connection recovers by itself, at the cost of a longer gap in the data."
        case .never: "Only sends keep-alives and never drops the link itself. Erup reconnects only if Bluetooth reports the link lost. A frozen speedometer can then stay frozen."
        }
    }

    /// How long after the keep-alive burst the app waits before it drops the link and reconnects. Nil: never.
    var reconnectGrace: Duration? {
        switch self {
        case .quick: .seconds(2)
        case .patient: .seconds(11)
        case .never: nil
        }
    }

    /// The setting now. Reads the stored value each time, so a change applies at once.
    nonisolated static var current: StallRecovery {
        UserDefaults.standard.string(forKey: storageKey).flatMap(StallRecovery.init(rawValue:)) ?? defaultValue
    }
}

/// How rides are cut. The defaults are what Erup always did.
enum RideSettings {
    static let joinWithinKey = "rides.joinWithinMinutes"
    static let endAfterStandingKey = "rides.endAfterStandingMinutes"

    static let defaultJoinMinutes = 5
    static let defaultStandingMinutes = 2
    /// Minutes; 0 turns joining off.
    static let joinOptions = [0, 2, 5, 10, 15]
    static let standingOptions = [1, 2, 3, 5]

    /// A ride that starts within this long after the previous one ended continues it. Zero: never.
    nonisolated static var joinWithin: TimeInterval {
        minutes(forKey: joinWithinKey, default: defaultJoinMinutes, allowed: joinOptions) * 60
    }

    /// How long standing still ends a ride.
    nonisolated static var endAfterStanding: TimeInterval {
        minutes(forKey: endAfterStandingKey, default: defaultStandingMinutes, allowed: standingOptions) * 60
    }

    nonisolated static var detectorConfiguration: RideDetector.Configuration {
        var configuration = RideDetector.Configuration()
        configuration.stationaryTimeout = endAfterStanding
        return configuration
    }

    /// A stored value that is not one of the offered choices falls back to the default, so a damaged setting can
    /// never turn joining into something absurd.
    private nonisolated static func minutes(forKey key: String, default fallback: Int, allowed: [Int]) -> TimeInterval {
        let stored = UserDefaults.standard.object(forKey: key) as? Int ?? fallback
        return TimeInterval(allowed.contains(stored) ? stored : fallback)
    }
}
