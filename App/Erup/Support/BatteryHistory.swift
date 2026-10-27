import Foundation
import ScooterAnalytics

/// Everything the Battery page works out from the ride history, in one pass. It is computed when the history changes,
/// not every time the live battery reading does (several times a second).
struct BatteryHistory: Equatable {
    struct Consumption: Equatable {
        let current: Double
        let previous: Double?
    }

    struct Efficiency: Identifiable, Equatable {
        let id: UUID
        let date: Date
        let whPerKm: Double
    }

    struct Resistance: Equatable {
        let date: Date
        let milliohm: Double
    }

    /// The subset of a ride the page needs, so the computation does not depend on the stored model object.
    struct Entry: Sendable {
        let id: UUID
        let startedAt: Date
        let endedAt: Date
        let distanceKm: Double
        let energyWh: Double
        let batteryStart: Int
        let batteryEnd: Int
        let maxSpeedKmh: Double
        let regenWh: Double?
        let internalResistanceOhm: Double?

        var batteryUsed: Int { batteryStart - batteryEnd }

        init(
            id: UUID, startedAt: Date, endedAt: Date? = nil, distanceKm: Double, energyWh: Double,
            batteryStart: Int = 0, batteryEnd: Int = 0, maxSpeedKmh: Double = 0, regenWh: Double? = nil,
            internalResistanceOhm: Double?
        ) {
            self.id = id
            self.startedAt = startedAt
            self.endedAt = endedAt ?? startedAt
            self.distanceKm = distanceKm
            self.energyWh = energyWh
            self.batteryStart = batteryStart
            self.batteryEnd = batteryEnd
            self.maxSpeedKmh = maxSpeedKmh
            self.regenWh = regenWh
            self.internalResistanceOhm = internalResistanceOhm
        }
    }

    static let empty = BatteryHistory(entries: [])
    /// Resistance of a typical pack, used until a ride has measured one.
    static let typicalResistanceOhm = 0.18

    var rideCount = 0
    var totalDistanceKm = 0.0
    var totalEnergyWh = 0.0
    var monthRides = 0
    var monthDistanceKm = 0.0
    var monthEnergyWh = 0.0
    var consumption: Consumption?
    /// Oldest first, for drawing left to right.
    var efficiency: [Efficiency] = []
    var resistances: [Resistance] = []
    var packResistanceOhm = typicalResistanceOhm
    var lastRide: Entry?
    /// Charge to charge, oldest first.
    var cycles: [ChargeCycles.Cycle] = []

    /// `entries` must be ordered newest first.
    init(entries: [Entry], now: Date = .now) {
        rideCount = entries.count
        lastRide = entries.first
        cycles = ChargeCycles.cycles(from: entries.map {
            ChargeCycles.Ride(
                startedAt: $0.startedAt, endedAt: $0.endedAt, distanceKm: $0.distanceKm, energyWh: $0.energyWh,
                batteryStart: $0.batteryStart, batteryEnd: $0.batteryEnd, maxSpeedKmh: $0.maxSpeedKmh, regenWh: $0.regenWh
            )
        })
        let monthAgo = now.addingTimeInterval(-30 * 86_400)
        for entry in entries {
            totalDistanceKm += entry.distanceKm
            totalEnergyWh += entry.energyWh
            if entry.startedAt >= monthAgo {
                monthRides += 1
                monthDistanceKm += entry.distanceKm
                monthEnergyWh += entry.energyWh
            }
        }

        let usable = entries.filter { $0.distanceKm >= 0.5 && $0.energyWh > 0 }
        func average(_ slice: ArraySlice<Entry>) -> Double? {
            let distance = slice.reduce(0) { $0 + $1.distanceKm }
            guard distance > 0 else { return nil }
            return slice.reduce(0) { $0 + $1.energyWh } / distance
        }
        if let current = average(usable.prefix(10)) {
            let older = usable.dropFirst(10).prefix(10)
            consumption = Consumption(current: current, previous: older.count >= 3 ? average(older) : nil)
        }

        let recent = entries.prefix(30)
        efficiency = recent.reversed().compactMap { entry in
            entry.distanceKm >= 0.1 ? Efficiency(id: entry.id, date: entry.startedAt, whPerKm: entry.energyWh / entry.distanceKm) : nil
        }
        resistances = recent.reversed().compactMap { entry in
            entry.internalResistanceOhm.map { Resistance(date: entry.startedAt, milliohm: $0 * 1000) }
        }
        let measured = entries.prefix(10).compactMap(\.internalResistanceOhm).sorted()
        packResistanceOhm = measured.isEmpty ? Self.typicalResistanceOhm : measured[measured.count / 2]
    }

    /// Stable, rising slowly or rising, from the first half of the recorded resistances against the second.
    var resistanceTrend: (label: String, detail: String, rising: Bool, fast: Bool)? {
        let values = resistances.map(\.milliohm)
        guard values.count >= 4 else { return nil }
        let half = values.count / 2
        let early = values.prefix(half).reduce(0, +) / Double(half)
        let late = values.suffix(half).reduce(0, +) / Double(half)
        let change = (late - early) / early * 100
        switch change {
        case ..<5: return ("Stable", "No meaningful change over your recorded rides.", false, false)
        case ..<15: return ("Rising slowly", "A small rise is normal as a battery ages.", true, false)
        default: return ("Rising", "Resistance is climbing faster than usual. Check the battery if range is also dropping.", true, true)
        }
    }

    static func == (lhs: BatteryHistory, rhs: BatteryHistory) -> Bool {
        lhs.rideCount == rhs.rideCount && lhs.totalDistanceKm == rhs.totalDistanceKm && lhs.totalEnergyWh == rhs.totalEnergyWh
            && lhs.lastRide?.id == rhs.lastRide?.id && lhs.consumption == rhs.consumption && lhs.efficiency == rhs.efficiency
            && lhs.resistances == rhs.resistances && lhs.cycles == rhs.cycles
    }
}
