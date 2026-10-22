import CoreMotion
import Foundation
import ScooterAnalytics

/// Records the phone's motion and barometer during a ride and reduces them to one `PhoneSensors` value per second.
/// Raw 50 Hz data is never stored.
@MainActor
final class MotionRecorder {
    static let enabledKey = "rides.recordMotion"

    private struct Bucket {
        var sumSquares = 0.0
        var count = 0
        var peak = 0.0
        var rotation = 0.0
    }

    private let motion = CMMotionManager()
    private let altimeter = CMAltimeter()
    private var buckets: [Int: Bucket] = [:]
    private var altitudes: [(time: Date, meters: Double)] = []
    private var origin: Date?
    private var isRunning = false

    static var isEnabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }

    static var isAvailable: Bool { CMMotionManager().isDeviceMotionAvailable }

    func start() {
        let wantsRoughness = RideDisplaySettings.isRecordingRoughness()
        let wantsAltitude = RideDisplaySettings.isRecordingAltitude() && CMAltimeter.isRelativeAltitudeAvailable()
        guard !isRunning, (wantsRoughness && motion.isDeviceMotionAvailable) || wantsAltitude else { return }
        isRunning = true
        buckets = [:]
        altitudes = []
        let start = Date.now
        origin = start

        if wantsRoughness && motion.isDeviceMotionAvailable { startMotion() }

        if wantsAltitude {
            altimeter.startRelativeAltitudeUpdates(to: .main) { [weak self] data, _ in
                guard let self, let data else { return }
                self.altitudes.append((.now, data.relativeAltitude.doubleValue))
            }
        }
    }

    private func startMotion() {
        motion.deviceMotionUpdateInterval = 1.0 / 25
        motion.startDeviceMotionUpdates(to: .main) { [weak self] data, _ in
            guard let self, let data, let origin = self.origin else { return }
            let second = Int(Date.now.timeIntervalSince(origin))
            let a = data.userAcceleration
            let magnitude = (a.x * a.x + a.y * a.y + a.z * a.z).squareRoot()
            let r = data.rotationRate
            let rotation = (r.x * r.x + r.y * r.y + r.z * r.z).squareRoot() * 180 / .pi
            var bucket = self.buckets[second, default: Bucket()]
            bucket.sumSquares += magnitude * magnitude
            bucket.count += 1
            bucket.peak = max(bucket.peak, magnitude)
            bucket.rotation = max(bucket.rotation, rotation)
            self.buckets[second] = bucket
        }
    }

    /// Stops recording and returns the per-second values keyed by seconds since `start()`.
    func stop() -> (origin: Date, seconds: [Int: PhoneSensors])? {
        guard isRunning, let origin else { return nil }
        isRunning = false
        motion.stopDeviceMotionUpdates()
        altimeter.stopRelativeAltitudeUpdates()
        defer {
            buckets = [:]
            altitudes = []
            self.origin = nil
        }

        var result: [Int: PhoneSensors] = [:]
        for (second, bucket) in buckets where bucket.count > 0 {
            result[second] = PhoneSensors(
                vibrationG: (bucket.sumSquares / Double(bucket.count)).squareRoot(),
                peakG: bucket.peak,
                rotationDegPerSecond: bucket.rotation
            )
        }
        for (time, meters) in altitudes {
            let second = Int(time.timeIntervalSince(origin))
            var value = result[second] ?? PhoneSensors()
            value.altitudeMeters = meters
            result[second] = value
        }
        return result.isEmpty ? nil : (origin, result)
    }
}
