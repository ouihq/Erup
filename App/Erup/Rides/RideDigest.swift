import Foundation
import ScooterAnalytics

/// Everything the ride detail page needs from the stored samples, worked out once off the main actor:
/// a thinned copy for drawing and totals taken from every sample.
struct RideDigest: Sendable {
    static let drawnPointLimit = 200

    let samples: [RideSample]
    let drawn: [RideSample]
    let climbMeters: Double?
    let descentMeters: Double?
    let averageVibrationG: Double?
    let peakG: Double?
    let hasTemperatures: Bool
    let hasElevation: Bool
    let hasVibration: Bool

    init(samples: [RideSample]) {
        self.samples = samples
        let step = max(1, samples.count / Self.drawnPointLimit)
        drawn = samples.enumerated().compactMap { $0.offset % step == 0 || $0.offset == samples.count - 1 ? $0.element : nil }

        let altitudes = samples.compactMap { $0.sensors?.altitudeMeters }
        hasElevation = altitudes.count > 1
        var climb = 0.0, descent = 0.0
        // Barometer readings wobble by a few centimetres, so only changes of half a metre or more count as a climb.
        var reference = altitudes.first ?? 0
        for altitude in altitudes.dropFirst() where abs(altitude - reference) >= 0.5 {
            if altitude > reference { climb += altitude - reference } else { descent += reference - altitude }
            reference = altitude
        }
        climbMeters = hasElevation ? climb : nil
        descentMeters = hasElevation ? descent : nil

        let vibrations = samples.compactMap { $0.sensors?.vibrationG }
        hasVibration = !vibrations.isEmpty
        averageVibrationG = vibrations.isEmpty ? nil : vibrations.reduce(0, +) / Double(vibrations.count)
        peakG = samples.compactMap { $0.sensors?.peakG }.max()
        hasTemperatures = samples.contains { $0.controllerTemperature != nil }
    }
}
