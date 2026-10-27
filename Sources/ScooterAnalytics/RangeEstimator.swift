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
    /// How many charges the capacity was worked out from. Zero when it is the rating, a value the rider set, or learned from single rides.
    public let calibrationCycles: Int

    public init(
        whPerKm: Double, capacityWh: Double, isCapacityCalibrated: Bool, typicalWhPerKm: ClosedRange<Double>? = nil, calibrationCycles: Int = 0
    ) {
        self.whPerKm = whPerKm
        self.capacityWh = capacityWh
        self.isCapacityCalibrated = isCapacityCalibrated
        self.typicalWhPerKm = typicalWhPerKm
        self.calibrationCycles = calibrationCycles
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
    /// A charge must use at least this many battery points to say anything about the capacity. Levels are whole percents,
    /// so over 25 points the rounding is a few percent at worst, against ten percent for a ride that used ten.
    public static let minimumCycleUse = 25
    /// Only the newest charges count, since the capacity of a pack changes slowly but does change.
    public static let calibrationCycleLimit = 6

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
        if let learned = capacityFromCharges(rides) {
            return RangeModel(
                whPerKm: whPerKm, capacityWh: clamped(learned.capacityWh, nominalCapacityWh), isCapacityCalibrated: true,
                typicalWhPerKm: typical, calibrationCycles: learned.cycles
            )
        }
        let calibration = usable.filter { $0.batteryStart - $0.batteryEnd >= minimumCalibrationRideUse }
        let usedPoints = calibration.reduce(0) { $0 + ($1.batteryStart - $1.batteryEnd) }
        guard usedPoints >= minimumCalibrationTotalUse else {
            // Not enough battery use to learn the capacity yet: the pack's rated capacity is the best guess.
            return nominalCapacityWh.map { RangeModel(whPerKm: whPerKm, capacityWh: $0, isCapacityCalibrated: false, typicalWhPerKm: typical) }
        }
        let capacity = calibration.reduce(0) { $0 + $1.energyWh } / (Double(usedPoints) / 100)
        return RangeModel(whPerKm: whPerKm, capacityWh: clamped(capacity, nominalCapacityWh), isCapacityCalibrated: true, typicalWhPerKm: typical)
    }

    /// Whole-percent readings make single rides noisy; a real pack stays close to its rating.
    private static func clamped(_ capacity: Double, _ nominal: Double?) -> Double {
        guard let nominal else { return capacity }
        return min(max(capacity, nominal * 0.5), nominal * 1.2)
    }

    /// The capacity from whole charges: the energy used between two charges over the share of the battery it took. A charge
    /// is told from the next by the level rising by `ChargeCycles.chargeJump` points or more between two rides.
    /// `rides` must be ordered newest first.
    static func capacityFromCharges(_ rides: [RideEnergyRecord]) -> (capacityWh: Double, cycles: Int)? {
        var groups: [[RideEnergyRecord]] = []
        for ride in rides {
            if let oldest = groups.last?.last, oldest.batteryStart - ride.batteryEnd < ChargeCycles.chargeJump {
                groups[groups.count - 1].append(ride)
            } else {
                groups.append([ride])
            }
        }
        var energy = 0.0, used = 0.0, count = 0
        for group in groups {
            guard let newest = group.first, let oldest = group.last else { continue }
            let drop = oldest.batteryStart - newest.batteryEnd
            let groupEnergy = group.reduce(0) { $0 + max($1.energyWh, 0) }
            guard drop >= minimumCycleUse, groupEnergy > 0 else { continue }
            energy += groupEnergy
            used += Double(drop)
            count += 1
            if count == calibrationCycleLimit { break }
        }
        return count > 0 ? (energy / (used / 100), count) : nil
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
