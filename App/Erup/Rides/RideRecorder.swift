import Foundation
import ScooterAnalytics
import SwiftData

@MainActor
final class RideRecorder {
    static let gpsKey = "rides.recordGPS"
    static let capacityKey = "battery.capacityWh"
    private static let disconnectGrace: Duration = .seconds(60)
    private static let historyLimit = 50

    private let store: ScooterStore
    private let context: ModelContext
    private let track = TrackRecorder()
    private var detector = RideDetector()
    private var finishTask: Task<Void, Never>?
    private var wasConnected = false

    init(store: ScooterStore, container: ModelContainer) {
        self.store = store
        context = container.mainContext
        track.onError = { [weak store] message in store?.report(message) }
        refreshRideContext()
    }

    func ingest(_ sample: TelemetrySample) {
        for event in detector.ingest(sample) { handle(event) }
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
        finishTask = Task {
            do { try await Task.sleep(for: Self.disconnectGrace) } catch { return }
            for event in self.detector.finish() { self.handle(event) }
        }
    }

    private func handle(_ event: RideDetector.Event) {
        switch event {
        case .started:
            if UserDefaults.standard.bool(forKey: Self.gpsKey) { track.start() }
        case .ended(let summary):
            save(summary, track: track.stop())
        case .discarded:
            _ = track.stop()
        }
    }

    private func save(_ summary: RideSummary, track: [TrackPoint]) {
        do {
            context.insert(try Ride.make(from: summary, track: track))
            try context.save()
        } catch {
            store.report("The ride could not be saved: \(error.localizedDescription)")
            return
        }
        refreshRideContext()
    }

    func refreshRideContext() {
        var descriptor = FetchDescriptor<Ride>(sortBy: [SortDescriptor(\.startedAt, order: .reverse)])
        descriptor.fetchLimit = Self.historyLimit
        do {
            let rides = try context.fetch(descriptor)
            let manual = UserDefaults.standard.double(forKey: Self.capacityKey)
            let model = RangeEstimator.model(rides: rides.map(\.energyRecord), manualCapacityWh: manual > 0 ? manual : nil)
            store.updateRideContext(rangeModel: model, lastRide: rides.first?.snapshotSummary)
        } catch {
            store.report("Ride history could not be loaded: \(error.localizedDescription)")
        }
    }
}
