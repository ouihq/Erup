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

    public var duration: TimeInterval { endedAt.timeIntervalSince(startedAt) }
    public var batteryUsed: Int { batteryStart - batteryEnd }
    public var whPerKm: Double? { distanceKm >= 0.1 ? energyWh / distanceKm : nil }
}
