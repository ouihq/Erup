import Foundation

public struct RideEnergyRecord: Equatable, Sendable {
    public let distanceKm: Double
    public let energyWh: Double
    public let batteryStart: Int
    public let batteryEnd: Int

    public init(distanceKm: Double, energyWh: Double, batteryStart: Int, batteryEnd: Int) {
        self.distanceKm = distanceKm
        self.energyWh = energyWh
        self.batteryStart = batteryStart
        self.batteryEnd = batteryEnd
    }
}

public struct RangeModel: Equatable, Sendable {
    public let whPerKm: Double
    public let capacityWh: Double
    public let isCapacityCalibrated: Bool

    public func rangeKm(batteryPercent: Int) -> Double {
        capacityWh * Double(max(0, min(100, batteryPercent))) / 100 / whPerKm
    }
}

/// Range from the rider's own recent consumption. The pack capacity is the manual value if given,
/// otherwise calibrated from rides that used a large share of the battery. Battery percent is coarse,
/// so the calibration needs several points of battery use before it reports anything.
public enum RangeEstimator {
    public static let recentRideCount = 10
    public static let minimumRideDistanceKm = 0.5
    public static let minimumTotalDistanceKm = 3.0
    public static let minimumCalibrationRideUse = 10
    public static let minimumCalibrationTotalUse = 20

    /// `rides` must be ordered newest first.
    public static func model(rides: [RideEnergyRecord], manualCapacityWh: Double?) -> RangeModel? {
        let usable = rides.filter { $0.distanceKm >= minimumRideDistanceKm && $0.energyWh > 0 }
        let recent = Array(usable.prefix(recentRideCount))
        let distance = recent.reduce(0) { $0 + $1.distanceKm }
        guard distance >= minimumTotalDistanceKm else { return nil }
        let whPerKm = recent.reduce(0) { $0 + $1.energyWh } / distance

        if let manualCapacityWh, manualCapacityWh > 0 {
            return RangeModel(whPerKm: whPerKm, capacityWh: manualCapacityWh, isCapacityCalibrated: false)
        }
        let calibration = usable.filter { $0.batteryStart - $0.batteryEnd >= minimumCalibrationRideUse }
        let usedPoints = calibration.reduce(0) { $0 + ($1.batteryStart - $1.batteryEnd) }
        guard usedPoints >= minimumCalibrationTotalUse else { return nil }
        let capacity = calibration.reduce(0) { $0 + $1.energyWh } / (Double(usedPoints) / 100)
        return RangeModel(whPerKm: whPerKm, capacityWh: capacity, isCapacityCalibrated: true)
    }
}
