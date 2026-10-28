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
    /// Temperatures in °C. Absent in rides recorded before 1.3.
    public var controllerTemperature: Int?
    public var motorTemperature: Int?
    /// Phone sensors, averaged over the sample's second. Absent when the sensor was off or unavailable.
    public var sensors: PhoneSensors?

    public init(
        offset: TimeInterval, speedKmh: Double, powerWatts: Double, batteryPercent: Int, voltage: Double,
        controllerTemperature: Int? = nil, motorTemperature: Int? = nil, sensors: PhoneSensors? = nil
    ) {
        self.offset = offset
        self.speedKmh = speedKmh
        self.powerWatts = powerWatts
        self.batteryPercent = batteryPercent
        self.voltage = voltage
        self.controllerTemperature = controllerTemperature
        self.motorTemperature = motorTemperature
        self.sensors = sensors
    }
}

/// What the phone felt during one second of a ride. Orientation independent, so it works in any pocket or mount.
public struct PhoneSensors: Codable, Equatable, Sendable {
    /// Height change since the ride began, in metres, from the barometer.
    public var altitudeMeters: Double?
    /// Root-mean-square of the phone's acceleration without gravity, in g. A measure of road roughness.
    public var vibrationG: Double?
    /// Strongest acceleration without gravity within the second, in g. Braking, bumps and kerbs.
    public var peakG: Double?
    /// Strongest rotation rate within the second, in degrees per second. Leaning and cornering.
    public var rotationDegPerSecond: Double?

    public init(altitudeMeters: Double? = nil, vibrationG: Double? = nil, peakG: Double? = nil, rotationDegPerSecond: Double? = nil) {
        self.altitudeMeters = altitudeMeters
        self.vibrationG = vibrationG
        self.peakG = peakG
        self.rotationDegPerSecond = rotationDegPerSecond
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
    /// Energy recovered by braking, measured while riding. Nil for rides recorded before this was measured.
    public let regenWh: Double?

    public init(
        startedAt: Date, endedAt: Date, distanceKm: Double, averageSpeedKmh: Double, maxSpeedKmh: Double,
        energyWh: Double, batteryStart: Int, batteryEnd: Int, maxControllerTemperature: Int,
        maxMotorTemperature: Int, internalResistanceOhm: Double?, samples: [RideSample], regenWh: Double? = nil
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
        self.regenWh = regenWh
    }

    public func replacingSamples(_ samples: [RideSample]) -> RideSummary {
        RideSummary(
            startedAt: startedAt, endedAt: endedAt, distanceKm: distanceKm, averageSpeedKmh: averageSpeedKmh,
            maxSpeedKmh: maxSpeedKmh, energyWh: energyWh, batteryStart: batteryStart, batteryEnd: batteryEnd,
            maxControllerTemperature: maxControllerTemperature, maxMotorTemperature: maxMotorTemperature,
            internalResistanceOhm: internalResistanceOhm, samples: samples, regenWh: regenWh
        )
    }

    public var duration: TimeInterval { endedAt.timeIntervalSince(startedAt) }
    public var batteryUsed: Int { batteryStart - batteryEnd }
    public var whPerKm: Double? { distanceKm >= 0.1 ? energyWh / distanceKm : nil }

    /// Rides that start within this long after the previous one ended count as one trip, for example a stop
    /// at a shop or a ride the connection cut in two. The app passes the rider's own window instead.
    public static let mergeGap: TimeInterval = 10 * 60

    /// True when this ride started shortly after `previous` ended. A `window` of zero turns joining off.
    ///
    /// The gap is measured from the end of `previous`, which for a ride that standing still ended is the moment
    /// it stopped moving, not the moment the ride was closed. A window at or below the standing time therefore
    /// never joins such a ride: the gap is always longer than the time it took to decide the ride was over.
    public func shouldMerge(after previous: RideSummary, within window: TimeInterval = RideSummary.mergeGap) -> Bool {
        let gap = startedAt.timeIntervalSince(previous.endedAt)
        return window > 0 && gap >= 0 && gap <= window
    }

    /// One ride from `previous` followed by this one. Distance and energy add up, the average speed is taken
    /// over the riding time without the pause, and this ride's samples are shifted onto the combined timeline.
    public func merged(after previous: RideSummary) -> RideSummary {
        let shift = startedAt.timeIntervalSince(previous.startedAt)
        // The phone's height is measured from where each part began, so this part continues from where the earlier one ended.
        let heightBase = previous.samples.last { $0.sensors?.altitudeMeters != nil }?.sensors?.altitudeMeters ?? 0
        let shifted = samples.map { sample -> RideSample in
            var sensors = sample.sensors
            if let altitude = sensors?.altitudeMeters { sensors?.altitudeMeters = altitude + heightBase }
            return RideSample(
                offset: sample.offset + shift, speedKmh: sample.speedKmh, powerWatts: sample.powerWatts,
                batteryPercent: sample.batteryPercent, voltage: sample.voltage,
                controllerTemperature: sample.controllerTemperature, motorTemperature: sample.motorTemperature, sensors: sensors
            )
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
            samples: previous.samples + shifted,
            // One side unknown means the total is unknown: the detail then estimates it from the samples.
            regenWh: previous.regenWh.flatMap { earlier in regenWh.map { earlier + $0 } }
        )
    }
}
