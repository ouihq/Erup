import SwiftUI

/// The scooter's PIN and the PIN Erup sends when locking.
struct SecuritySettingsView: View {
    @Environment(ScooterStore.self) private var store
    @State private var showsPINChange = false
    @State private var showsLockPIN = false

    private var isConnected: Bool { store.connection.isConnected }

    var body: some View {
        Form {
            Section {
                Toggle("Require PIN", isOn: Binding(
                    get: { store.settings.pinEnabled ?? false },
                    set: { enabled in Task { await store.setPINEnabled(enabled) } }
                ))
                .disabled(!isConnected || store.settings.pinEnabled == nil)
                .overlay(alignment: .trailing) {
                    if store.isLoadingSettings && store.settings.pinEnabled == nil { ProgressView() }
                }
                Button("Change PIN") {
                    SettingsAuth.require("Change the scooter PIN.") { showsPINChange = true }
                }
                .disabled(!isConnected)
            } header: {
                Text("Scooter PIN")
            } footer: {
                Text(isConnected
                     ? "With a PIN, the scooter asks for it before it can be locked or unlocked."
                     : "Connect to the scooter to change its PIN.")
            }

            Section {
                Button("PIN used for locking") {
                    SettingsAuth.require("Show the PIN Erup sends when locking.") { showsLockPIN = true }
                }
            } header: {
                Text("On this iPhone")
            } footer: {
                Text("Erup sends this PIN before every lock and unlock. It is stored only on this iPhone, in the Keychain, and needs Face ID or your passcode to change.")
            }

            Section {
                Label("The Bluetooth lock and PIN are not real security. Anyone nearby with a Bluetooth app can change the PIN, and the lock only blocks the throttle. Use a physical lock as well.", systemImage: "exclamationmark.shield")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Lock and PIN")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: store.connection) {
            if isConnected { await store.refreshSettings() }
        }
        .sheet(isPresented: $showsPINChange) { PINChangeSheet() }
        .sheet(isPresented: $showsLockPIN) { LockPINSheet() }
    }
}
