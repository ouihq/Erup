@preconcurrency import ActivityKit
import Foundation

@MainActor
final class LiveActivityController {
    private static let endGrace: Duration = .seconds(60)

    private var activity: Activity<ScooterActivityAttributes>?
    private var lastState: ScooterActivityAttributes.ContentState?
    private var lastUpdate = ContinuousClock.now
    private var endTask: Task<Void, Never>?
    private var startUnavailable = false
    var onError: (@MainActor (String) -> Void)?

    init() {
        activity = Activity<ScooterActivityAttributes>.activities.first
        lastState = activity?.content.state
    }

    func handle(_ snapshot: ScooterSnapshot) async {
        guard let state = Self.contentState(from: snapshot) else {
            scheduleEndIfNeeded()
            return
        }
        guard snapshot.isConnected else {
            await push(state)
            scheduleEndIfNeeded()
            return
        }
        endTask?.cancel()
        endTask = nil

        if activity == nil {
            startActivity(with: state)
        } else {
            await push(state)
        }
    }

    private func startActivity(with state: ScooterActivityAttributes.ContentState) {
        guard !startUnavailable, ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        do {
            activity = try Activity.request(
                attributes: ScooterActivityAttributes(scooterName: "Scooter"),
                content: .init(state: state, staleDate: nil)
            )
            lastState = state
            lastUpdate = .now
        } catch {
            // Hosts that don't declare NSSupportsLiveActivities (e.g. sideloaded
            // via LiveContainer) can never start one; don't retry or alert.
            startUnavailable = true
        }
    }

    private func push(_ state: ScooterActivityAttributes.ContentState) async {
        guard let activity else { return }
        let elapsed = ContinuousClock.now - lastUpdate
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        guard ActivityUpdatePolicy.shouldUpdate(from: lastState, to: state, secondsSinceLastUpdate: seconds) else { return }
        lastState = state
        lastUpdate = .now
        await activity.update(.init(state: state, staleDate: nil))
    }

    private func scheduleEndIfNeeded() {
        guard activity != nil, endTask == nil else { return }
        endTask = Task {
            do { try await Task.sleep(for: Self.endGrace) } catch { return }
            await self.endNow()
        }
    }

    private func endNow() async {
        let finalContent = lastState.map { ActivityContent(state: $0, staleDate: nil) }
        await activity?.end(finalContent, dismissalPolicy: .after(.now.addingTimeInterval(120)))
        activity = nil
        lastState = nil
        endTask = nil
    }

    static func contentState(from snapshot: ScooterSnapshot) -> ScooterActivityAttributes.ContentState? {
        guard let battery = snapshot.batteryPercent else { return nil }
        return .init(
            speedKmh: Int(snapshot.speedKmh.rounded()),
            batteryPercent: battery,
            rangeKm: snapshot.rangeKm.map { Int($0.rounded()) },
            gearRaw: snapshot.gearRaw ?? 0,
            tripKm: snapshot.tripKm ?? 0,
            headlightOn: snapshot.headlightOn,
            isConnected: snapshot.isConnected,
            usesMiles: snapshot.usesMiles
        )
    }
}
