import Foundation

public struct TelemetrySample: Equatable, Sendable {
    public let date: Date
    public let speedKmh: Double
    public let voltage: Double
    public let current: Double
    public let batteryPercent: Int
    public let controllerTemperature: Int
    public let motorTemperature: Int

    public init(
        date: Date, speedKmh: Double, voltage: Double, current: Double,
        batteryPercent: Int, controllerTemperature: Int, motorTemperature: Int
    ) {
        self.date = date
        self.speedKmh = speedKmh
        self.voltage = voltage
        self.current = current
        self.batteryPercent = batteryPercent
        self.controllerTemperature = controllerTemperature
        self.motorTemperature = motorTemperature
    }

    public var powerWatts: Double { voltage * current }
}

public struct RideSample: Codable, Equatable, Sendable {
    public let offset: TimeInterval
    public let speedKmh: Double
    public let powerWatts: Double
    public let batteryPercent: Int
    public let voltage: Double

    public init(offset: TimeInterval, speedKmh: Double, powerWatts: Double, batteryPercent: Int, voltage: Double) {
        self.offset = offset
        self.speedKmh = speedKmh
        self.powerWatts = powerWatts
        self.batteryPercent = batteryPercent
        self.voltage = voltage
    }
}

public struct RideSummary: Equatable, Sendable {
    public let startedAt: Date
    public let endedAt: Date
    public let distanceKm: Double
    public let averageSpeedKmh: Double
    public let maxSpeedKmh: Double
    public let energyWh: Double
    public let batteryStart: Int
    public let batteryEnd: Int
    public let maxControllerTemperature: Int
    public let maxMotorTemperature: Int
    public let internalResistanceOhm: Double?
    public let samples: [RideSample]

    public init(
        startedAt: Date, endedAt: Date, distanceKm: Double, averageSpeedKmh: Double, maxSpeedKmh: Double,
        energyWh: Double, batteryStart: Int, batteryEnd: Int, maxControllerTemperature: Int,
        maxMotorTemperature: Int, internalResistanceOhm: Double?, samples: [RideSample]
    ) {
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.distanceKm = distanceKm
        self.averageSpeedKmh = averageSpeedKmh
        self.maxSpeedKmh = maxSpeedKmh
        self.energyWh = energyWh
        self.batteryStart = batteryStart
        self.batteryEnd = batteryEnd
        self.maxControllerTemperature = maxControllerTemperature
        self.maxMotorTemperature = maxMotorTemperature
        self.internalResistanceOhm = internalResistanceOhm
        self.samples = samples
    }

    public var duration: TimeInterval { endedAt.timeIntervalSince(startedAt) }
    public var batteryUsed: Int { batteryStart - batteryEnd }
    public var whPerKm: Double? { distanceKm >= 0.1 ? energyWh / distanceKm : nil }

    /// Rides that start within this long after the previous one ended count as one trip, for example a stop
    /// at a shop or a traffic light that ended the first ride.
    public static let mergeGap: TimeInterval = 5 * 60

    /// True when this ride started shortly after `previous` ended.
    public func shouldMerge(after previous: RideSummary) -> Bool {
        let gap = startedAt.timeIntervalSince(previous.endedAt)
        return gap >= 0 && gap <= Self.mergeGap
    }

    /// One ride from `previous` followed by this one. Distance and energy add up, the average speed is taken
    /// over the riding time without the pause, and this ride's samples are shifted onto the combined timeline.
    public func merged(after previous: RideSummary) -> RideSummary {
        let shift = startedAt.timeIntervalSince(previous.startedAt)
        let shifted = samples.map {
            RideSample(offset: $0.offset + shift, speedKmh: $0.speedKmh, powerWatts: $0.powerWatts,
                       batteryPercent: $0.batteryPercent, voltage: $0.voltage)
        }
        let distance = previous.distanceKm + distanceKm
        let ridingTime = previous.duration + duration
        let resistances = [previous.internalResistanceOhm, internalResistanceOhm].compactMap { $0 }
        return RideSummary(
            startedAt: previous.startedAt,
            endedAt: endedAt,
            distanceKm: distance,
            averageSpeedKmh: ridingTime > 0 ? distance / (ridingTime / 3600) : 0,
            maxSpeedKmh: max(previous.maxSpeedKmh, maxSpeedKmh),
            energyWh: previous.energyWh + energyWh,
            batteryStart: previous.batteryStart,
            batteryEnd: batteryEnd,
            maxControllerTemperature: max(previous.maxControllerTemperature, maxControllerTemperature),
            maxMotorTemperature: max(previous.maxMotorTemperature, maxMotorTemperature),
            internalResistanceOhm: resistances.isEmpty ? nil : resistances.reduce(0, +) / Double(resistances.count),
            samples: previous.samples + shifted
        )
    }
}
