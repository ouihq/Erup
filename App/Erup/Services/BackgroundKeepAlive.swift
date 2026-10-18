import CoreLocation
import Foundation
import UIKit

/// When the session that keeps the app running in the background should be on, as a pure decision.
///
/// iOS suspends an app in the background unless something legitimate keeps it running. Bluetooth alone only wakes
/// it briefly for each notification. A location session, held while the scooter is connected (ideally started while
/// the app is on screen), keeps the app running with the screen off, so keep-alives and ride tracking do not stop.
enum KeepRunningPolicy {
    enum Action: Equatable {
        case start
        case keepRunning
        case stopNow
        case stopAfterGrace
        case idle
    }

    /// How long the session stays up after the scooter disconnects, so a short cutoff does not end it.
    static let disconnectGrace: Duration = .seconds(120)

    static func action(enabled: Bool, connected: Bool, running: Bool) -> Action {
        switch (enabled, connected) {
        case (true, true):
            if running { return .keepRunning }
            // iOS documents that a location session should begin while the app is on screen, but when the scooter
            // reconnects with the app already in the background it is better to try than to give up. The log says
            // whether the first location update arrived, so a start from the background that did nothing is visible.
            return .start
        case (false, _):
            return running ? .stopNow : .idle
        case (true, false):
            return running ? .stopAfterGrace : .idle
        }
    }
}

enum BackgroundActivity {
    /// What iOS says about the app's remaining background time. A huge number means the app is being kept running.
    @MainActor
    static var remainingDescription: String {
        let remaining = UIApplication.shared.backgroundTimeRemaining
        if remaining > 100_000 { return "unlimited (the app is being kept running)" }
        return String(format: "%.0f s left before iOS suspends the app", remaining)
    }
}

@MainActor
final class BackgroundKeepAlive {
    nonisolated static let storageKey = "background.keepRunning"
    /// On by default: the scooter link only stays reliable with the screen off while iOS keeps the app running.
    nonisolated static let defaultEnabled = true

    private var serviceSession: CLServiceSession?
    private var activitySession: CLBackgroundActivitySession?
    private var updates: Task<Void, Never>?
    private var pendingStop: Task<Void, Never>?
    var onError: (@MainActor (String) -> Void)?

    var isRunning: Bool { updates != nil }

    nonisolated static var isEnabled: Bool { UserDefaults.standard.object(forKey: storageKey) as? Bool ?? defaultEnabled }

    /// Call whenever the setting, the connection or the app state changes.
    func update(connected: Bool, inForeground: Bool) {
        switch KeepRunningPolicy.action(enabled: Self.isEnabled, connected: connected, running: isRunning) {
        case .start:
            cancelPendingStop()
            start(inForeground: inForeground)
        case .keepRunning:
            cancelPendingStop()
        case .stopNow:
            cancelPendingStop()
            stop(reason: "turned off")
        case .stopAfterGrace:
            guard pendingStop == nil else { return }
            pendingStop = Task {
                do { try await Task.sleep(for: KeepRunningPolicy.disconnectGrace) } catch { return }
                self.pendingStop = nil
                self.stop(reason: "the scooter stayed disconnected")
            }
        case .idle:
            break
        }
    }

    private func cancelPendingStop() {
        pendingStop?.cancel()
        pendingStop = nil
    }

    private func start(inForeground: Bool) {
        DiagnosticLog.shared.log(.app, "keep-running session started with the app in the \(inForeground ? "foreground" : "BACKGROUND (best effort)")")
        serviceSession = CLServiceSession(authorization: .whenInUse)
        activitySession = CLBackgroundActivitySession()
        updates = Task {
            do {
                // Location updates are what keep the process running; their values are not used here.
                var announced = false
                for try await update in CLLocationUpdate.liveUpdates(.default) {
                    if !announced, update.location != nil {
                        announced = true
                        DiagnosticLog.shared.log(.app, "keep-running session works: the first location update arrived")
                    }
                    if update.authorizationDenied {
                        DiagnosticLog.shared.log(.error, "keep-running session: location access is off")
                        self.onError?("Location access is off, so Erup cannot stay connected with the screen off. Allow it in Settings.")
                        break
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                DiagnosticLog.shared.log(.error, "keep-running session stopped: \(error.localizedDescription)")
            }
            self.updates = nil
        }
    }

    private func stop(reason: String) {
        guard isRunning else { return }
        DiagnosticLog.shared.log(.app, "keep-running session stopped (\(reason))")
        updates?.cancel()
        updates = nil
        serviceSession?.invalidate()
        activitySession?.invalidate()
        serviceSession = nil
        activitySession = nil
    }
}
