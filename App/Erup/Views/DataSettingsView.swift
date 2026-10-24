import SwiftData
import SwiftUI

/// Storage use, export and reset.
struct DataSettingsView: View {
    @Environment(ScooterStore.self) private var store
    @Environment(\.modelContext) private var context
    @Query private var rides: [Ride]
    @State private var showsExport = false
    @State private var confirmsReset = false
    @State private var rideDataBytes: Int64?

    var body: some View {
        Form {
            Section {
                LabeledContent("Rides", value: "\(rides.count)")
                LabeledContent("Space used") {
                    if let rideDataBytes {
                        Text(rideDataBytes, format: .byteCount(style: .file))
                    } else {
                        ProgressView()
                    }
                }
            } header: {
                Text("Storage")
            } footer: {
                Text("Sensor data and routes are stored compressed, with every value kept exactly as recorded.")
            }

            Section {
                NavigationLink {
                    BackupSettingsView()
                } label: {
                    Label("Backup and restore", systemImage: "icloud.and.arrow.up")
                }
            } footer: {
                Text("Keep a copy of your rides in iCloud Drive or a file, and put it back after reinstalling Erup.")
            }

            Section {
                Button {
                    showsExport = true
                } label: {
                    Label("Export data…", systemImage: "square.and.arrow.up")
                }
            } footer: {
                Text("Save rides, sensor data and routes for a period you choose as a zip of plain files, to open in a spreadsheet. It can't be restored into Erup; use a backup for that.")
            }

            Section {
                Button("Reset Erup…", role: .destructive) {
                    SettingsAuth.require("Reset Erup and delete its data.") { confirmsReset = true }
                }
            } footer: {
                Text("Deletes all rides and sensor data, forgets the scooter and removes the saved PIN and all settings from this iPhone. This cannot be undone.")
            }
        }
        .navigationTitle("Data and storage")
        .navigationBarTitleDisplayMode(.inline)
        .task { rideDataBytes = await StorageMaintenance.rideDataBytes() }
        .sheet(isPresented: $showsExport) { ExportView() }
        .confirmationDialog("Reset Erup?", isPresented: $confirmsReset, titleVisibility: .visible) {
            Button("Delete everything and reset", role: .destructive) { reset() }
        } message: {
            Text("Export your data first if you want to keep it.")
        }
    }

    private func reset() {
        Task {
            do {
                try await AppReset.perform(store: store, context: context)
                rideDataBytes = await StorageMaintenance.rideDataBytes()
            } catch {
                store.report("The reset failed: \(error.localizedDescription)")
            }
        }
    }
}
