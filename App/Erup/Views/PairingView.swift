import SwiftUI

struct PairingView: View {
    @Environment(ScooterStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section {
                Text("Turn the scooter on, keep it close, and make sure no other phone or the Pure app is connected to it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Section("Scooters nearby") {
                if store.discovered.isEmpty {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Searching for ZYD_ scooters")
                    }
                }
                ForEach(store.discovered) { scooter in
                    Button {
                        Task { await store.pair(with: scooter) }
                    } label: {
                        HStack {
                            Text(scooter.name)
                            Spacer()
                            Image(systemName: "wifi", variableValue: signalStrength(scooter.rssi))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityLabel("Pair with \(scooter.name)")
                }
            }
        }
        .navigationTitle("Pair a scooter")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await store.beginPairing()
        }
        .onDisappear {
            Task { await store.endPairing() }
        }
        // Once a scooter was chosen the connection takes over, so the list is no longer needed.
        .onChange(of: store.connection) { _, state in
            if state == .connecting || state == .connected { dismiss() }
        }
    }

    private func signalStrength(_ rssi: Int) -> Double {
        min(1, max(0, Double(rssi + 100) / 60))
    }
}

#Preview {
    NavigationStack { PairingView() }.environment(ScooterStore.preview(connection: .scanning))
}
