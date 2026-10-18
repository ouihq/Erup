import Foundation
import WidgetKit

@MainActor
final class SnapshotWriter {
    private static let minimumWriteInterval: TimeInterval = 5
    private static let minimumReloadInterval: TimeInterval = 300

    private var lastWritten: ScooterSnapshot?
    private var lastWriteDate = Date.distantPast
    private var lastReloadDate = Date.distantPast
    private var groupUnavailable = false
    var onError: (@MainActor (String) -> Void)?

    func handle(_ snapshot: ScooterSnapshot) {
        guard !groupUnavailable else { return }
        let now = snapshot.updatedAt
        let structural = Self.hasStructuralChange(from: lastWritten, to: snapshot)
        guard structural || now.timeIntervalSince(lastWriteDate) >= Self.minimumWriteInterval else { return }
        do {
            try SnapshotStore.save(snapshot)
        } catch SnapshotStore.StoreError.appGroupUnavailable {
            // Only widgets need the shared container, so the app keeps working without it.
            groupUnavailable = true
            return
        } catch {
            onError?(error.localizedDescription)
            return
        }
        lastWritten = snapshot
        lastWriteDate = now
        if structural || now.timeIntervalSince(lastReloadDate) >= Self.minimumReloadInterval {
            lastReloadDate = now
            WidgetCenter.shared.reloadAllTimelines()
            ControlCenter.shared.reloadAllControls()
        }
    }

    nonisolated static func hasStructuralChange(from old: ScooterSnapshot?, to new: ScooterSnapshot) -> Bool {
        guard let old else { return true }
        return old.isConnected != new.isConnected
            || old.batteryPercent != new.batteryPercent
            || old.gearRaw != new.gearRaw
            || old.headlightOn != new.headlightOn
            || old.isLocked != new.isLocked
            || old.lastRide != new.lastRide
    }
}
