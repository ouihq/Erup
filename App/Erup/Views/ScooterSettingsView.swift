import ScooterProtocol
import SwiftUI

/// Everything about the paired scooter: connection, name and its display.
struct ScooterSettingsView: View {
    @Environment(ScooterStore.self) private var store
    @State private var showsRename = false
    @State private var confirmsForget = false

    private var isConnected: Bool { store.connection.isConnected }

    var body: some View {
        Form {
            Section {
                ConnectionBadge(state: store.connection, searchingSince: store.searchingSince, lastSeen: store.lastTelemetryDate, plain: true)
            } footer: {
                if store.connection.needsPairing {
                    Text("Rides, battery history and settings work without a scooter. Live data needs one nearby.")
                } else if !isConnected {
                    Text("Erup reconnects by itself when the scooter is on and nearby.")
                }
            }

            if store.connection.needsPairing {
                Section {
                    NavigationLink {
                        PairingView()
                    } label: {
                        Label("Pair a scooter", systemImage: "plus.circle.fill")
                    }
                }
            } else {
                Section {
                    LabeledContent("Name") {
                        Button("Rename") { showsRename = true }
                            .disabled(!isConnected)
                    }
                    if let code = store.settings.deviceDescription {
                        // The number the scooter reports is its ZYD code, the one Pure support asks for.
                        LabeledContent("ZYD code", value: code)
                    }
                } header: {
                    Text("Identity")
                } footer: {
                    Text(isConnected ? "The new name applies after the scooter restarts." : "Connect to the scooter to rename it.")
                }

                Section {
                    Toggle("Miles on scooter display", isOn: Binding(
                        get: { store.effectiveRegister?.imperialUnits ?? false },
                        set: { store.setImperialUnits($0) }
                    ))
                    .disabled(!store.isReady)
                } header: {
                    Text("Scooter display")
                } footer: {
                    Text("Changes what the scooter's own display shows. The units inside Erup are set under Settings → Units.")
                }

                Section {
                    Button("Forget this scooter", role: .destructive) { confirmsForget = true }
                } footer: {
                    Text("Erup disconnects and stops looking for it. Your rides stay on this iPhone.")
                }
            }
        }
        .navigationTitle("Scooter")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: store.connection) {
            if isConnected { await store.refreshSettings() }
        }
        .sheet(isPresented: $showsRename) { RenameSheet() }
        .confirmationDialog("Forget this scooter?", isPresented: $confirmsForget, titleVisibility: .visible) {
            Button("Forget scooter", role: .destructive) { Task { await store.forgetScooter() } }
        } message: {
            Text("You can pair it again at any time.")
        }
    }
}
