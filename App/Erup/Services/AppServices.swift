import Foundation
import SwiftData

@MainActor
final class AppServices {
    private let store: ScooterStore
    private let snapshots = SnapshotWriter()
    private let liveActivity = LiveActivityController()
    private let notifications = NotificationService()
    private var alerts = AlertEngine()
    private let rides: RideRecorder
    private let keepRunning = BackgroundKeepAlive()
    private var defaultsObserver: NSObjectProtocol?
    private var darwinObserver: DarwinObserver?
    private var isDrainingCommands = false
    private var requestedNotificationAuthorization = false

    init(store: ScooterStore, container: ModelContainer) {
        self.store = store
        rides = RideRecorder(store: store, container: container)
        store.onSample = { [weak rides] sample in rides?.ingest(sample) }
        store.onBackground = { [weak rides] in rides?.persistDraftNow() }
        store.onForeground = { [weak self] in self?.refreshKeepRunning() }
        // The setting lives in UserDefaults, so changing it in Settings takes effect at once.
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshKeepRunning()
                self?.rides.applySettings()
            }
        }
        store.onRideContextInvalidated = { [weak rides] in rides?.refreshRideContext() }
        let report: @MainActor (String) -> Void = { [weak store] message in store?.report(message) }
        snapshots.onError = report
        keepRunning.onError = report
        liveActivity.onError = report
        notifications.onError = report

        store.onSnapshot = { [weak self] snapshot in self?.handle(snapshot) }
        ScooterCommandCenter.shared.executor = { [weak store] command in
            guard let store else { throw LinkFailure.notConnected }
            try await store.execute(command)
        }
        darwinObserver = DarwinObserver { [weak self] in
            Task { @MainActor in await self?.drainQueuedCommands() }
        }
        Task { await drainQueuedCommands() }
    }

    private func refreshKeepRunning() {
        keepRunning.update(connected: store.connection.isConnected, inForeground: store.isInForeground)
    }

    private func handle(_ snapshot: ScooterSnapshot) {
        keepRunning.update(connected: snapshot.isConnected, inForeground: store.isInForeground)
        rides.connectionChanged(snapshot.isConnected)
        snapshots.handle(snapshot)
        Task { await liveActivity.handle(snapshot) }

        if snapshot.isConnected, !requestedNotificationAuthorization {
            requestedNotificationAuthorization = true
            Task { await notifications.requestAuthorizationIfNeeded() }
        }
        guard let battery = snapshot.batteryPercent,
              let controller = snapshot.controllerTemperature,
              let motor = snapshot.motorTemperature else { return }
        let reading = AlertEngine.Reading(
            batteryPercent: battery,
            controllerTemperature: controller,
            motorTemperature: motor,
            current: snapshot.current ?? 0,
            speedKmh: snapshot.speedKmh,
            isConnected: snapshot.isConnected,
            date: snapshot.updatedAt
        )
        for alert in alerts.evaluate(reading) {
            let (title, body) = NotificationService.text(for: alert)
            store.logAlert("\(title). \(body)")
            Task { await notifications.post(alert) }
        }
    }

    /// Commands queued by the widget extension when its intent could not reach the app process directly.
    func drainQueuedCommands() async {
        guard !isDrainingCommands else { return }
        isDrainingCommands = true
        defer { isDrainingCommands = false }
        do {
            let queued = try CommandQueueFile.read()
            guard !queued.isEmpty else { return }
            try CommandQueueFile.write([])
            for item in queued where Date().timeIntervalSince(item.date) < 30 {
                do {
                    try await store.execute(item.command)
                } catch {
                    store.report(error.localizedDescription)
                }
            }
        } catch SnapshotStore.StoreError.appGroupUnavailable {
            // Only the widget extension queues commands through the shared container, and it cannot without
            // the App Group. The app itself works, so there is nothing to tell the rider on every launch.
            return
        } catch {
            store.report(error.localizedDescription)
        }
    }
}
