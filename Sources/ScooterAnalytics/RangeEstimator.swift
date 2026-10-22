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
    /// Consumption of the rider's typical (middle half of) recent rides, lowest first. Nil with too few rides to say.
    public let typicalWhPerKm: ClosedRange<Double>?

    public init(whPerKm: Double, capacityWh: Double, isCapacityCalibrated: Bool, typicalWhPerKm: ClosedRange<Double>? = nil) {
        self.whPerKm = whPerKm
        self.capacityWh = capacityWh
        self.isCapacityCalibrated = isCapacityCalibrated
        self.typicalWhPerKm = typicalWhPerKm
    }

    /// The likely range: the best and worst end of the rider's typical consumption.
    public func rangeBandKm(batteryPercent: Int) -> ClosedRange<Double>? {
        guard let typicalWhPerKm, typicalWhPerKm.lowerBound > 0 else { return nil }
        let energy = capacityWh * Double(max(0, min(100, batteryPercent))) / 100
        return (energy / typicalWhPerKm.upperBound)...(energy / typicalWhPerKm.lowerBound)
    }

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
    public static func model(rides: [RideEnergyRecord], manualCapacityWh: Double?, nominalCapacityWh: Double? = nil) -> RangeModel? {
        let usable = rides.filter { $0.distanceKm >= minimumRideDistanceKm && $0.energyWh > 0 }
        let recent = Array(usable.prefix(recentRideCount))
        let distance = recent.reduce(0) { $0 + $1.distanceKm }
        guard distance >= minimumTotalDistanceKm else { return nil }
        let whPerKm = recent.reduce(0) { $0 + $1.energyWh } / distance
        let typical = typicalBand(recent.map { $0.energyWh / $0.distanceKm })

        if let manualCapacityWh, manualCapacityWh > 0 {
            return RangeModel(whPerKm: whPerKm, capacityWh: manualCapacityWh, isCapacityCalibrated: false, typicalWhPerKm: typical)
        }
        let calibration = usable.filter { $0.batteryStart - $0.batteryEnd >= minimumCalibrationRideUse }
        let usedPoints = calibration.reduce(0) { $0 + ($1.batteryStart - $1.batteryEnd) }
        guard usedPoints >= minimumCalibrationTotalUse else {
            // Not enough battery use to learn the capacity yet: the pack's rated capacity is the best guess.
            return nominalCapacityWh.map { RangeModel(whPerKm: whPerKm, capacityWh: $0, isCapacityCalibrated: false, typicalWhPerKm: typical) }
        }
        var capacity = calibration.reduce(0) { $0 + $1.energyWh } / (Double(usedPoints) / 100)
        if let nominalCapacityWh {
            // Whole-percent readings make single rides noisy; a real pack stays close to its rating.
            capacity = min(max(capacity, nominalCapacityWh * 0.5), nominalCapacityWh * 1.2)
        }
        return RangeModel(whPerKm: whPerKm, capacityWh: capacity, isCapacityCalibrated: true, typicalWhPerKm: typical)
    }

    /// First and third quartile of the per-ride consumption, so one unusual ride doesn't stretch the band.
    private static func typicalBand(_ values: [Double]) -> ClosedRange<Double>? {
        guard values.count >= 4 else { return nil }
        let sorted = values.sorted()
        func quantile(_ q: Double) -> Double {
            let position = q * Double(sorted.count - 1)
            let lower = Int(position.rounded(.down)), upper = Int(position.rounded(.up))
            return sorted[lower] + (sorted[upper] - sorted[lower]) * (position - Double(lower))
        }
        return quantile(0.25)...quantile(0.75)
    }
}
