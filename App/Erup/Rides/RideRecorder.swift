import Foundation
import ScooterAnalytics
import SwiftData

@MainActor
final class RideRecorder {
    static let gpsKey = "rides.recordGPS"
    static let capacityKey = "battery.capacityWh"
    private static let disconnectGrace: Duration = .seconds(300)
    private static let historyLimit = 50
    /// While riding, the ride is written to storage this often, so a killed or suspended app loses little.
    private static let draftInterval: TimeInterval = 10
    private static let draftAttemptInterval: TimeInterval = 2

    /// The stored row that follows the ride in progress. When the ride started shortly after a stored one,
    /// the row is that earlier ride and `base` is what it held before this ride began.
    private struct LiveRide {
        let ride: Ride
        let base: RideSummary?
        let baseTrack: [TrackPoint]
    }

    private let store: ScooterStore
    private let context: ModelContext
    private let track = TrackRecorder()
    private let motion = MotionRecorder()
    /// Called once a finished ride is stored, so a backup can follow.
    var onRideStored: (() -> Void)?
    private var detector = RideDetector(configuration: RideSettings.detectorConfiguration)
    private var finishTask: Task<Void, Never>?
    private var wasConnected = false
    private var live: LiveRide?
    private var lastDraftWrite = Date.distantPast
    private var lastDraftAttempt = Date.distantPast

    init(store: ScooterStore, container: ModelContainer) {
        self.store = store
        context = container.mainContext
        track.onError = { [weak store] message in store?.report(message) }
        refreshRideContext()
    }

    /// Picks up a changed ride setting. It applies from the next reading, even to a ride in progress.
    func applySettings() {
        detector.update(configuration: RideSettings.detectorConfiguration)
    }

    func ingest(_ sample: TelemetrySample) {
        for event in detector.ingest(sample) { handle(event) }
        guard detector.isRiding else { return }
        let sinceAttempt = sample.date.timeIntervalSince(lastDraftAttempt)
        let sinceWrite = sample.date.timeIntervalSince(lastDraftWrite)
        // Keep trying every couple of seconds until the ride is long enough to store, then every few seconds.
        if sinceWrite >= Self.draftInterval && sinceAttempt >= Self.draftAttemptInterval {
            lastDraftAttempt = sample.date
            if persistDraft() { lastDraftWrite = sample.date }
        }
    }

    /// Stores the ride in progress right now, for example when the app goes to the background.
    func persistDraftNow() {
        guard detector.isRiding else { return }
        if persistDraft() { lastDraftWrite = Date() }
    }

    func connectionChanged(_ isConnected: Bool) {
        guard isConnected != wasConnected else { return }
        wasConnected = isConnected
        if isConnected {
            finishTask?.cancel()
            finishTask = nil
            return
        }
        guard detector.isRiding else { return }
        DiagnosticLog.shared.log(.ride, "connection lost during a ride, stored it and waiting up to 5 min for a reconnect")
        persistDraftNow()
        finishTask = Task {
            do { try await Task.sleep(for: Self.disconnectGrace) } catch { return }
            for event in self.detector.finish() { self.handle(event) }
        }
    }

    private func handle(_ event: RideDetector.Event) {
        switch event {
        case .started:
            lastDraftWrite = .distantPast
            lastDraftAttempt = .distantPast
            if UserDefaults.standard.bool(forKey: Self.gpsKey) { track.start() }
            if MotionRecorder.isEnabled { motion.start() }
        case .ended(let summary):
            finalize(Self.merging(motion.stop(), into: summary), track: track.stop())
        case .discarded:
            _ = track.stop()
            _ = motion.stop()
            discardLive()
        }
    }

    /// Attaches the phone's per-second readings to the ride samples they belong to.
    private static func merging(_ recording: (origin: Date, seconds: [Int: PhoneSensors])?, into summary: RideSummary) -> RideSummary {
        guard let recording else { return summary }
        let shift = summary.startedAt.timeIntervalSince(recording.origin)
        var base: Double?
        let samples = summary.samples.map { sample -> RideSample in
            var sample = sample
            guard var sensors = recording.seconds[Int(sample.offset + shift)] else { return sample }
            if let altitude = sensors.altitudeMeters {
                base = base ?? altitude
                sensors.altitudeMeters = altitude - (base ?? altitude)
            }
            sample.sensors = sensors
            return sample
        }
        return summary.replacingSamples(samples)
    }

    // MARK: Storing a ride while it is in progress

    /// Writes the ride so far into its stored row, creating the row once the ride is long enough to keep.
    @discardableResult
    private func persistDraft() -> Bool {
        guard let current = detector.currentSummary() else { return false }
        do {
            let target = try liveRide(for: current)
            try write(current, track: track.currentPoints, to: target)
            try context.save()
            return true
        } catch {
            DiagnosticLog.shared.log(.error, "storing the ride failed: \(error.localizedDescription)")
            store.report("The ride could not be saved: \(error.localizedDescription)")
            return false
        }
    }

    private func liveRide(for current: RideSummary) throws -> LiveRide {
        if let live { return live }
        var latest = FetchDescriptor<Ride>(sortBy: [SortDescriptor(\.endedAt, order: .reverse)])
        latest.fetchLimit = 1
        let target: LiveRide
        if let previous = try context.fetch(latest).first, current.shouldMerge(after: try previous.summary(), within: RideSettings.joinWithin) {
            target = LiveRide(ride: previous, base: try previous.summary(), baseTrack: try previous.decodedTrack())
            DiagnosticLog.shared.log(.ride, "ride in progress continues the previous ride (stopped \(Int(current.startedAt.timeIntervalSince(previous.endedAt))) s ago)")
        } else {
            let ride = try Ride.make(from: current, track: [])
            context.insert(ride)
            target = LiveRide(ride: ride, base: nil, baseTrack: [])
            DiagnosticLog.shared.log(.ride, String(format: "ride stored while riding: %.2f km so far", current.distanceKm))
        }
        live = target
        return target
    }

    private func write(_ summary: RideSummary, track: [TrackPoint], to target: LiveRide) throws {
        if let base = target.base {
            try target.ride.overwrite(with: summary.merged(after: base), track: target.baseTrack + track)
        } else {
            try target.ride.overwrite(with: summary, track: track)
        }
    }

    /// The detector ended the ride: store its final numbers in the row that has followed it, or save it now.
    private func finalize(_ summary: RideSummary, track points: [TrackPoint]) {
        DiagnosticLog.shared.log(.ride, String(format: "ride ended: %.2f km, %d s", summary.distanceKm, Int(summary.duration)))
        defer { live = nil }
        do {
            if let live {
                try write(summary, track: points, to: live)
                try context.save()
            } else {
                try storeFinished(summary, track: points)
            }
        } catch {
            store.report("The ride could not be saved: \(error.localizedDescription)")
            return
        }
        refreshRideContext()
        onRideStored?()
    }

    /// The ride turned out too short to keep. Remove what was stored for it and restore an earlier ride it was merged into.
    private func discardLive() {
        guard let live else { return }
        DiagnosticLog.shared.log(.ride, "ride discarded as too short")
        self.live = nil
        do {
            if let base = live.base {
                try live.ride.overwrite(with: base, track: live.baseTrack)
            } else {
                context.delete(live.ride)
            }
            try context.save()
        } catch {
            store.report("The ride could not be saved: \(error.localizedDescription)")
        }
        refreshRideContext()
    }

    private func storeFinished(_ summary: RideSummary, track: [TrackPoint]) throws {
        var latest = FetchDescriptor<Ride>(sortBy: [SortDescriptor(\.endedAt, order: .reverse)])
        latest.fetchLimit = 1
        if let previous = try context.fetch(latest).first, summary.shouldMerge(after: try previous.summary(), within: RideSettings.joinWithin) {
            try previous.absorb(summary, track: track)
        } else {
            context.insert(try Ride.make(from: summary, track: track))
        }
        try context.save()
    }

    func refreshRideContext() {
        // A restore that replaced the rides, or a reset, deleted the row the ride in progress was writing into.
        if let live, live.ride.isDeleted || live.ride.modelContext == nil { self.live = nil }
        var descriptor = FetchDescriptor<Ride>(sortBy: [SortDescriptor(\.startedAt, order: .reverse)])
        descriptor.fetchLimit = Self.historyLimit
        do {
            let rides = try context.fetch(descriptor)
            let manual = UserDefaults.standard.double(forKey: Self.capacityKey)
            let model = RangeEstimator.model(rides: rides.map(\.energyRecord), manualCapacityWh: manual > 0 ? manual : nil, nominalCapacityWh: BatteryModel.nominalCapacityWh)
            store.updateRideContext(rangeModel: model, lastRide: rides.first?.snapshotSummary)
        } catch {
            store.report("Ride history could not be loaded: \(error.localizedDescription)")
        }
    }
}
