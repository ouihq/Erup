import SwiftData
import SwiftUI

@main
struct ErupApp: App {
    @State private var store: ScooterStore
    @State private var services: AppServices
    @AppStorage(AppearanceSetting.storageKey) private var appearance = AppearanceSetting.system
    private let container: ModelContainer

    init() {
        let store = ScooterStore(link: Self.makeLink())
        let container: ModelContainer
        do {
            #if targetEnvironment(simulator)
            container = ProcessInfo.processInfo.arguments.contains("-demo-data") ? Ride.previewContainer() : try ModelContainer(for: Ride.self)
            #else
            container = try ModelContainer(for: Ride.self)
            #endif
        } catch {
            store.report("Ride history is unavailable this session: \(error.localizedDescription)")
            container = try! ModelContainer(for: Ride.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        }
        self.container = container
        StorageMaintenance.packOldRides(container: container)
        _store = State(initialValue: store)
        _services = State(initialValue: AppServices(store: store, container: container))
        Task { await store.start() }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .preferredColorScheme(appearance.colorScheme)
        }
        .modelContainer(container)
    }

    private static func makeLink() -> any ScooterLink {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-mock-ignore-writes") {
            return MockScooter(behavior: .init(confirmsWrites: false, startsPaired: false))
        }
        if arguments.contains("-demo-parked") { return MockScooter(behavior: .init(simulatesRide: false, startsPaired: false)) }
        if arguments.contains("-demo") { return MockScooter(behavior: .init(startsPaired: false)) }
        #if targetEnvironment(simulator)
        return arguments.contains("-live") ? ScooterConnection() : MockScooter(behavior: .init(startsPaired: false))
        #else
        return ScooterConnection()
        #endif
    }
}
