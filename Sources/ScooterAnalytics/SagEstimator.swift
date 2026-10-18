import Foundation

/// Rough internal resistance estimate: (resting voltage - loaded voltage) / current.
/// Voltage also falls with state of charge, so only compare estimates taken at similar charge levels
/// and treat the trend as indicative, not a measurement.
public struct SagEstimator: Equatable, Sendable {
    public static let minimumLoadAmps = 5.0
    public static let restCurrentAmps = 0.5
    public static let maximumRestAge: TimeInterval = 120
    public static let maximumBatteryDelta = 3
    public static let minimumEstimates = 5
    public static let plausibleOhms = 0.01...1.5

    private var rest: (voltage: Double, battery: Int, date: Date)?
    public private(set) var estimates: [Double] = []

    public init() {}

    public mutating func beginCollecting() {
        estimates.removeAll()
    }

    public mutating func ingest(_ sample: TelemetrySample) {
        if abs(sample.current) < Self.restCurrentAmps {
            rest = (sample.voltage, sample.batteryPercent, sample.date)
            return
        }
        guard sample.current >= Self.minimumLoadAmps, let rest,
              sample.date.timeIntervalSince(rest.date) <= Self.maximumRestAge,
              abs(sample.batteryPercent - rest.battery) <= Self.maximumBatteryDelta,
              sample.voltage < rest.voltage else { return }
        let ohms = (rest.voltage - sample.voltage) / sample.current
        if Self.plausibleOhms.contains(ohms) { estimates.append(ohms) }
    }

    public var medianOhms: Double? {
        guard estimates.count >= Self.minimumEstimates else { return nil }
        let sorted = estimates.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }

    public static func == (lhs: SagEstimator, rhs: SagEstimator) -> Bool {
        lhs.estimates == rhs.estimates
    }
}
