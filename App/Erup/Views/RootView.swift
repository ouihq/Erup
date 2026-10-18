import SwiftData
import SwiftUI

struct RootView: View {
    @Environment(ScooterStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        // The app is usable without a scooter: rides, battery history and settings stay available.
        TabView {
            Tab("Ride", systemImage: "gauge.with.dots.needle.33percent") {
                NavigationStack {
                    DashboardView()
                        .navigationTitle("Erup")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItemGroup(placement: .topBarTrailing) {
                                NotificationBell()
                                NavigationLink {
                                    SettingsView()
                                } label: {
                                    Label("Settings", systemImage: "gearshape")
                                }
                            }
                        }
                }
            }
            Tab("Rides", systemImage: "point.topleft.down.to.point.bottomright.curvepath") {
                NavigationStack { RidesView() }
            }
            Tab("Battery", systemImage: "battery.75percent") {
                NavigationStack { BatteryView() }
            }
        }
        .safeAreaInset(edge: .top) { AlertBanner() }
        .animation(.default, value: store.alertMessage)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { store.refreshAfterForeground() }
        }
    }
}

#Preview("Connected, light") {
    RootView()
        .environment(ScooterStore.preview())
        .modelContainer(Ride.previewContainer())
}

#Preview("Connected, dark") {
    RootView()
        .environment(ScooterStore.preview())
        .modelContainer(Ride.previewContainer())
        .preferredColorScheme(.dark)
}
