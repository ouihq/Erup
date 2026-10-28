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

/// How rides are cut: how long standing still ends a ride, and how long a pause may be for the next ride to
/// continue the last one.
///
/// Both numbers measure the same thing, the pause since the scooter stopped moving, so they only make sense
/// together. A ride is closed once the pause reaches the standing time, which means a pause that ever ends a ride
/// is at least that long; a join window at or below the standing time can therefore never reach such a ride.
/// With both at the same value — how Erup comes — every pause longer than the standing time starts a new ride,
/// and joining is left for the rides a dropped connection or a gap in the data cut in two, where the pause can be
/// shorter. Set the window above the standing time to stitch longer stops back into one ride.
enum RideSettings {
    static let joinWithinKey = "rides.joinWithinMinutes"
    static let endAfterStandingKey = "rides.endAfterStandingMinutes"

    static let defaultJoinMinutes = 10
    static let defaultStandingMinutes = 10
    /// Minutes; 0 turns joining off. Both go up to half an hour, which is a long coffee and still one trip.
    static let joinOptions = [0, 2, 5, 10, 15, 20, 30]
    static let standingOptions = [1, 2, 3, 5, 10, 15, 20, 30]

    /// A ride that starts within this long after the previous one ended continues it. Zero: never.
    nonisolated static var joinWithin: TimeInterval {
        minutes(forKey: joinWithinKey, default: defaultJoinMinutes, allowed: joinOptions) * 60
    }

    /// How long standing still ends a ride.
    nonisolated static var endAfterStanding: TimeInterval {
        minutes(forKey: endAfterStandingKey, default: defaultStandingMinutes, allowed: standingOptions) * 60
    }

    /// Whether the join window reaches a ride that standing still ended, which needs a window longer than the
    /// standing time. False with the two set equally, and with joining off.
    nonisolated static var joiningReachesStandstillSplits: Bool {
        joinWithin > 0 && joinWithin > endAfterStanding
    }

    /// What the two settings mean together, for the settings screen and the diagnostic report.
    static func pauseSummary(joinMinutes: Int, standingMinutes: Int) -> String {
        let standing = "\(standingMinutes) min"
        guard joinMinutes > 0 else {
            return "Standing still for \(standing) ends a ride, and every ride stands on its own."
        }
        guard joinMinutes > standingMinutes else {
            return "Standing still for \(standing) ends a ride, and a longer pause always starts a new one. Joining is left for a ride that a dropped connection cut in two, which it repairs within \(joinMinutes) min."
        }
        return "Standing still for \(standing) ends a ride, and riding again within \(joinMinutes) min of the stop continues it. A longer pause starts a new ride."
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
