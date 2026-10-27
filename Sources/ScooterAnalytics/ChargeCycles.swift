import Foundation

/// The rides between two charges, worked out from the battery level each ride started and ended at.
///
/// The app does not see the scooter being charged unless it is open and connected, so a charge is recognised afterwards:
/// when a ride starts with clearly more battery than the previous one ended with, the pack was charged in between.
public enum ChargeCycles {
    /// What a ride says about the battery.
    public struct Ride: Equatable, Sendable {
        public let startedAt: Date
        public let endedAt: Date
        public let distanceKm: Double
        public let energyWh: Double
        public let batteryStart: Int
        public let batteryEnd: Int
        public let maxSpeedKmh: Double
        public let regenWh: Double?

        public init(
            startedAt: Date, endedAt: Date, distanceKm: Double, energyWh: Double,
            batteryStart: Int, batteryEnd: Int, maxSpeedKmh: Double = 0, regenWh: Double? = nil
        ) {
            self.startedAt = startedAt
            self.endedAt = endedAt
            self.distanceKm = distanceKm
            self.energyWh = energyWh
            self.batteryStart = batteryStart
            self.batteryEnd = batteryEnd
            self.maxSpeedKmh = maxSpeedKmh
            self.regenWh = regenWh
        }
    }

    public struct Cycle: Equatable, Identifiable, Sendable {
        /// 1 for the oldest cycle.
        public let number: Int
        public let startedAt: Date
        public let endedAt: Date
        public let rideCount: Int
        public let distanceKm: Double
        public let energyWh: Double
        public let ridingTime: TimeInterval
        public let maxSpeedKmh: Double
        /// Battery level the cycle started at, which is roughly where the charge before it ended.
        public let startPercent: Int
        public let endPercent: Int
        /// Energy recovered by braking, when every ride of the cycle measured it.
        public let regenWh: Double?

        public var id: Int { number }
        public var usedPercent: Int { max(0, startPercent - endPercent) }
        public var whPerKm: Double? { distanceKm >= 0.5 ? energyWh / distanceKm : nil }

        /// How far this cycle would have gone on a full battery, from how far it did go on the part that was used.
        /// Only trustworthy once a fifth of the battery has been used, since the level is whole percents.
        public var projectedRangeKm: Double? {
            usedPercent >= 20 && distanceKm > 0 ? distanceKm / Double(usedPercent) * 100 : nil
        }
    }

    /// Battery points the level must rise between two rides for the pack to count as charged in between.
    public static let chargeJump = 8

    /// Cycles from the oldest to the newest. `rides` may be in any order.
    public static func cycles(from rides: [Ride], chargeJump: Int = ChargeCycles.chargeJump) -> [Cycle] {
        let ordered = rides.sorted { $0.startedAt < $1.startedAt }
        var groups: [[Ride]] = []
        for ride in ordered {
            if let last = groups.last?.last, ride.batteryStart - last.batteryEnd < chargeJump {
                groups[groups.count - 1].append(ride)
            } else {
                groups.append([ride])
            }
        }
        return groups.enumerated().map { index, group in
            let regens = group.map(\.regenWh)
            return Cycle(
                number: index + 1,
                startedAt: group.first?.startedAt ?? .distantPast,
                endedAt: group.last?.endedAt ?? .distantPast,
                rideCount: group.count,
                distanceKm: group.reduce(0) { $0 + $1.distanceKm },
                energyWh: group.reduce(0) { $0 + $1.energyWh },
                ridingTime: group.reduce(0) { $0 + $1.endedAt.timeIntervalSince($1.startedAt) },
                maxSpeedKmh: group.map(\.maxSpeedKmh).max() ?? 0,
                startPercent: group.first?.batteryStart ?? 0,
                endPercent: group.last?.batteryEnd ?? 0,
                regenWh: regens.contains { $0 == nil } ? nil : regens.compactMap { $0 }.reduce(0, +)
            )
        }
    }

    /// Whether the pack has been charged since the last ride, going by the level the scooter shows now.
    public static func isChargedSinceLastRide(lastRideEnd: Int, currentPercent: Int, chargeJump: Int = ChargeCycles.chargeJump) -> Bool {
        currentPercent - lastRideEnd >= chargeJump
    }
}
