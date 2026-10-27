import Foundation
import ScooterAnalytics
import SwiftData

struct TrackPoint: Codable, Equatable, Sendable {
    let latitude: Double
    let longitude: Double
    let timestamp: Date
}

@Model
final class Ride {
    @Attribute(.unique) var id: UUID
    var startedAt: Date
    var endedAt: Date
    var distanceKm: Double
    var averageSpeedKmh: Double
    var maxSpeedKmh: Double
    var energyWh: Double
    var batteryStart: Int
    var batteryEnd: Int
    var maxControllerTemperature: Int
    var maxMotorTemperature: Int
    var internalResistanceOhm: Double?
    /// Energy recovered by braking, measured while riding. Nil for rides recorded before it was measured.
    var regenWh: Double?
    @Attribute(.externalStorage) var samplesData: Data
    @Attribute(.externalStorage) var trackData: Data?

    init(
        id: UUID = UUID(), startedAt: Date, endedAt: Date, distanceKm: Double, averageSpeedKmh: Double,
        maxSpeedKmh: Double, energyWh: Double, batteryStart: Int, batteryEnd: Int,
        maxControllerTemperature: Int, maxMotorTemperature: Int, internalResistanceOhm: Double?,
        samplesData: Data, trackData: Data?, regenWh: Double? = nil
    ) {
        self.id = id
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
        self.samplesData = samplesData
        self.trackData = trackData
        self.regenWh = regenWh
    }

    static func make(from summary: RideSummary, track: [TrackPoint]) throws -> Ride {
        return Ride(
            startedAt: summary.startedAt, endedAt: summary.endedAt, distanceKm: summary.distanceKm,
            averageSpeedKmh: summary.averageSpeedKmh, maxSpeedKmh: summary.maxSpeedKmh,
            energyWh: summary.energyWh, batteryStart: summary.batteryStart, batteryEnd: summary.batteryEnd,
            maxControllerTemperature: summary.maxControllerTemperature,
            maxMotorTemperature: summary.maxMotorTemperature,
            internalResistanceOhm: summary.internalResistanceOhm,
            samplesData: try PackedData.pack(summary.samples),
            trackData: track.isEmpty ? nil : try PackedData.pack(track),
            regenWh: summary.regenWh
        )
    }

    /// This stored ride as a summary, so a following ride can be merged into it.
    func summary() throws -> RideSummary {
        RideSummary(
            startedAt: startedAt, endedAt: endedAt, distanceKm: distanceKm, averageSpeedKmh: averageSpeedKmh,
            maxSpeedKmh: maxSpeedKmh, energyWh: energyWh, batteryStart: batteryStart, batteryEnd: batteryEnd,
            maxControllerTemperature: maxControllerTemperature, maxMotorTemperature: maxMotorTemperature,
            internalResistanceOhm: internalResistanceOhm, samples: try decodedSamples(), regenWh: regenWh
        )
    }

    /// Replaces everything stored for this ride with `summary` and `track`.
    func overwrite(with summary: RideSummary, track: [TrackPoint]) throws {
        startedAt = summary.startedAt
        endedAt = summary.endedAt
        distanceKm = summary.distanceKm
        averageSpeedKmh = summary.averageSpeedKmh
        maxSpeedKmh = summary.maxSpeedKmh
        energyWh = summary.energyWh
        batteryStart = summary.batteryStart
        batteryEnd = summary.batteryEnd
        maxControllerTemperature = summary.maxControllerTemperature
        maxMotorTemperature = summary.maxMotorTemperature
        internalResistanceOhm = summary.internalResistanceOhm
        regenWh = summary.regenWh
        samplesData = try PackedData.pack(summary.samples)
        trackData = track.isEmpty ? nil : try PackedData.pack(track)
    }

    /// Replaces this ride with the combination of itself and a ride that followed it closely.
    func absorb(_ next: RideSummary, track nextTrack: [TrackPoint]) throws {
        try overwrite(with: next.merged(after: try summary()), track: try decodedTrack() + nextTrack)
    }

    var duration: TimeInterval { endedAt.timeIntervalSince(startedAt) }
    var batteryUsed: Int { batteryStart - batteryEnd }
    var whPerKm: Double? { distanceKm >= 0.1 ? energyWh / distanceKm : nil }

    func decodedSamples() throws -> [RideSample] {
        try PackedData.decode([RideSample].self, from: samplesData)
    }

    func decodedTrack() throws -> [TrackPoint] {
        guard let trackData else { return [] }
        return try PackedData.decode([TrackPoint].self, from: trackData)
    }

    var energyRecord: RideEnergyRecord {
        RideEnergyRecord(distanceKm: distanceKm, energyWh: energyWh, batteryStart: batteryStart, batteryEnd: batteryEnd)
    }

    var snapshotSummary: ScooterSnapshot.RideSummary {
        .init(startedAt: startedAt, distanceKm: distanceKm, duration: duration, averageSpeedKmh: averageSpeedKmh)
    }
}

extension Ride {
    @MainActor
    static func previewContainer() -> ModelContainer {
        let container = try! ModelContainer(for: Ride.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let samples = (0..<600).map { second -> RideSample in
            let t = Double(second)
            let speed = max(0, 18 + 6 * sin(t / 40))
            let acceleration = 6.0 / 40 * cos(t / 40)   // km/h per second
            // Pushing: power follows the speed and how hard it accelerates. Braking: energy comes back, up to about 180 W.
            let power = acceleration >= 0 ? speed * 14 + acceleration * 300 : max(-180, acceleration * 1800)
            return RideSample(
                offset: t, speedKmh: speed, powerWatts: power, batteryPercent: 80 - second / 60, voltage: 40.5 - speed / 50,
                controllerTemperature: 28 + second / 25, motorTemperature: 26 + second / 18,
                sensors: PhoneSensors(altitudeMeters: 6 * sin(t / 90), vibrationG: 0.03 + 0.02 * abs(sin(t / 7)), peakG: 0.2 + 0.1 * abs(sin(t / 11)), rotationDegPerSecond: 20 * abs(sin(t / 13)))
            )
        }
        let start = Date.now.addingTimeInterval(-86_400)
        for day in 0..<6 {
            let rideStart = start.addingTimeInterval(Double(-day) * 86_400)
            // Each route carries the timestamps of its own ride, so a moment in the charts finds its place on the map.
            let track = (0..<120).map { i in
                TrackPoint(latitude: 52.52 + Double(i) * 0.0002, longitude: 13.405 + sin(Double(i) / 15) * 0.002, timestamp: rideStart.addingTimeInterval(Double(i) * 5))
            }
            let ride = Ride(
                startedAt: rideStart, endedAt: rideStart.addingTimeInterval(600),
                distanceKm: 3 + Double(day), averageSpeedKmh: 18, maxSpeedKmh: 21, energyWh: Double(60 + day * 14),
                batteryStart: [44, 54, 64, 75, 86, 96][day], batteryEnd: [34, 44, 54, 64, 75, 86][day], maxControllerTemperature: 41, maxMotorTemperature: 48,
                internalResistanceOhm: 0.18 + Double(day) * 0.004,
                samplesData: try! PackedData.pack(samples), trackData: try! PackedData.pack(track)
            )
            container.mainContext.insert(ride)
        }
        // Older rides spread over the last year, so the statistics have something to show.
        for index in 0..<70 {
            let daysAgo = 7 + index * 5 + (index % 3)
            let when = Date.now.addingTimeInterval(-Double(daysAgo) * 86_400)
            let distance = 2 + Double((index * 7) % 9)
            let ride = Ride(
                startedAt: when, endedAt: when.addingTimeInterval(distance * 190),
                distanceKm: distance, averageSpeedKmh: 17 + Double(index % 4), maxSpeedKmh: 20 + Double((index * 5) % 12),
                energyWh: distance * (14 + Double(index % 5)),
                // Four rides to a charge: the oldest of each group starts full, the rest carry on from where the one before ended.
                batteryStart: 96 - (3 - index % 4) * 18, batteryEnd: 78 - (3 - index % 4) * 18,
                maxControllerTemperature: 40, maxMotorTemperature: 46, internalResistanceOhm: 0.18,
                samplesData: try! PackedData.pack(samples), trackData: nil
            )
            container.mainContext.insert(ride)
        }
        return container
    }
}
