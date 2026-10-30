import Foundation
import SwiftData

/// Puts the app back to how it was on first launch: no rides, no paired scooter, no saved PIN or settings.
@MainActor
enum AppReset {
    static func perform(store: ScooterStore, context: ModelContext) async throws {
        for ride in try context.fetch(FetchDescriptor<Ride>()) { context.delete(ride) }
        try context.save()
        store.invalidateRideContext()

        await store.forgetScooter()
        store.clearNotices()

        PINVault.pin = nil
        SnapshotStore.remove()
        if let bundle = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: bundle)
        }
        UserDefaults(suiteName: AppGroup.id)?.removePersistentDomain(forName: AppGroup.id)
    }
}
