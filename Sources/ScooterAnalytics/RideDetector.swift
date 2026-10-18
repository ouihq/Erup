import Foundation

public struct RideDetector: Sendable {
    public struct Configuration: Sendable {
        public var startSpeedKmh = 3.0
        public var startDuration: TimeInterval = 3
        public var stopSpeedKmh = 0.5
        public var stationaryTimeout: TimeInterval = 120
        /// A ride survives a gap in the data this long, for example a lagging link or a cutoff and reconnect.
        public var maximumGap: TimeInterval = 300
        /// Gaps longer than this add no distance or energy, so a pause in the data cannot invent kilometres.
        public var integrationLimit: TimeInterval = 5
        /// Starting a ride needs steady data, so a long gap resets the start check.
        public var startGap: TimeInterval = 30
        public var storedSampleInterval: TimeInterval = 1
        public var minimumDistanceKm = 0.05
        public var minimumDuration: TimeInterval = 15

        public init() {}
    }

    public enum Event: Equatable, Sendable {
        case started(Date)
        case ended(RideSummary)
        case discarded
    }

    private struct Accumulator: Sendable {
        let start: TelemetrySample
        var last: TelemetrySample
        var distanceKm = 0.0
        var energyWh = 0.0
        var maxSpeed: Double
        var maxController: Int
        var maxMotor: Int
        var samples: [RideSample]
        var lastStoredOffset: TimeInterval
        var stationarySince: Date?

        init(start: TelemetrySample) {
            self.start = start
            last = start
            maxSpeed = start.speedKmh
            maxController = start.controllerTemperature
            maxMotor = start.motorTemperature
            samples = [Self.rideSample(start, offset: 0)]
            lastStoredOffset = 0
        }

        static func rideSample(_ sample: TelemetrySample, offset: TimeInterval) -> RideSample {
            RideSample(
                offset: offset, speedKmh: sample.speedKmh, powerWatts: sample.powerWatts,
                batteryPercent: sample.batteryPercent, voltage: sample.voltage
            )
        }

        mutating func add(_ sample: TelemetrySample, storedInterval: TimeInterval, integrationLimit: TimeInterval) {
            let dt = sample.date.timeIntervalSince(last.date)
            if dt > 0, dt <= integrationLimit {
                distanceKm += (sample.speedKmh + last.speedKmh) / 2 * dt / 3600
                energyWh += (sample.powerWatts + last.powerWatts) / 2 * dt / 3600
            }
            maxSpeed = max(maxSpeed, sample.speedKmh)
            maxController = max(maxController, sample.controllerTemperature)
            maxMotor = max(maxMotor, sample.motorTemperature)
            let offset = sample.date.timeIntervalSince(start.date)
            if offset - lastStoredOffset >= storedInterval {
                samples.append(Self.rideSample(sample, offset: offset))
                lastStoredOffset = offset
            }
            last = sample
        }
    }

    private let configuration: Configuration
    private var pending: [TelemetrySample] = []
    private var accumulator: Accumulator?
    private var sag = SagEstimator()

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    public var isRiding: Bool { accumulator != nil }

    public mutating func ingest(_ sample: TelemetrySample) -> [Event] {
        var events: [Event] = []
        sag.ingest(sample)

        if var current = accumulator {
            if sample.date.timeIntervalSince(current.last.date) > configuration.maximumGap {
                events.append(close(current, endingAt: current.last.date))
                accumulator = nil
            } else {
                current.add(sample, storedInterval: configuration.storedSampleInterval, integrationLimit: configuration.integrationLimit)
                if sample.speedKmh < configuration.stopSpeedKmh {
                    current.stationarySince = current.stationarySince ?? sample.date
                } else {
                    current.stationarySince = nil
                }
                if let since = current.stationarySince,
                   sample.date.timeIntervalSince(since) >= configuration.stationaryTimeout {
                    events.append(close(current, endingAt: since))
                    accumulator = nil
                } else {
                    accumulator = current
                }
                return events
            }
        }

        events += detectStart(sample)
        return events
    }

    /// The ride so far, without ending it. Nil while no ride is in progress or while it is still too short
    /// to be kept. The app stores this while riding, so a ride survives the app being killed.
    public func currentSummary() -> RideSummary? {
        guard let current = accumulator, case .ended(let summary) = close(current, endingAt: current.last.date) else { return nil }
        return summary
    }

    /// Ends a ride in progress, for example after a long disconnect.
    public mutating func finish() -> [Event] {
        pending.removeAll()
        guard let current = accumulator else { return [] }
        accumulator = nil
        return [close(current, endingAt: current.stationarySince ?? current.last.date)]
    }

    private mutating func detectStart(_ sample: TelemetrySample) -> [Event] {
        guard sample.speedKmh > configuration.startSpeedKmh else {
            pending.removeAll()
            return []
        }
        if let last = pending.last, sample.date.timeIntervalSince(last.date) > configuration.startGap {
            pending.removeAll()
        }
        pending.append(sample)
        guard let first = pending.first,
              sample.date.timeIntervalSince(first.date) >= configuration.startDuration else { return [] }

        var started = Accumulator(start: first)
        for later in pending.dropFirst() {
            started.add(later, storedInterval: configuration.storedSampleInterval, integrationLimit: configuration.integrationLimit)
        }
        accumulator = started
        pending.removeAll()
        sag.beginCollecting()
        return [.started(first.date)]
    }

    private func close(_ ride: Accumulator, endingAt end: Date) -> Event {
        let duration = end.timeIntervalSince(ride.start.date)
        guard ride.distanceKm >= configuration.minimumDistanceKm, duration >= configuration.minimumDuration else {
            return .discarded
        }
        let kept = ride.samples.filter { $0.offset <= duration }
        let endBattery = kept.last?.batteryPercent ?? ride.last.batteryPercent
        return .ended(RideSummary(
            startedAt: ride.start.date,
            endedAt: end,
            distanceKm: ride.distanceKm,
            averageSpeedKmh: ride.distanceKm / (duration / 3600),
            maxSpeedKmh: ride.maxSpeed,
            energyWh: ride.energyWh,
            batteryStart: ride.start.batteryPercent,
            batteryEnd: endBattery,
            maxControllerTemperature: ride.maxController,
            maxMotorTemperature: ride.maxMotor,
            internalResistanceOhm: sag.medianOhms,
            samples: kept
        ))
    }
}
