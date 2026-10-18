import ScooterProtocol
import SwiftUI

struct SettingsView: View {
    @Environment(ScooterStore.self) private var store
    @AppStorage("useMiles") private var useMiles = false
    @AppStorage(AppearanceSetting.storageKey) private var appearance = AppearanceSetting.system
    @AppStorage(RideRecorder.gpsKey) private var recordsGPS = false

    var body: some View {
        Form {
            Section {
                NavigationLink {
                    ScooterSettingsView()
                } label: {
                    ScooterSummaryRow()
                }
            }

            Section {
                Picker(selection: $appearance) {
                    ForEach(AppearanceSetting.allCases) { Text($0.title).tag($0) }
                } label: {
                    SettingsLabel(title: "Appearance", symbol: "circle.lefthalf.filled", tint: .gray)
                }
                Picker(selection: $useMiles) {
                    Text("Kilometres").tag(false)
                    Text("Miles").tag(true)
                } label: {
                    SettingsLabel(title: "Units", symbol: "ruler.fill", tint: .gray)
                }
                NavigationLink {
                    NotificationCenterView()
                } label: {
                    HStack {
                        SettingsLabel(title: "Notifications", symbol: "bell.badge.fill", tint: .red)
                        Spacer()
                        if store.unreadNoticeCount > 0 {
                            Text("\(store.unreadNoticeCount)")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section {
                Toggle(isOn: $recordsGPS) {
                    SettingsLabel(title: "Record routes", symbol: "location.fill")
                }
                NavigationLink {
                    ServiceSettingsView()
                } label: {
                    SettingsLabel(title: "Service reminder", symbol: "wrench.and.screwdriver.fill", tint: .gray)
                }
            } header: {
                Text("Rides")
            } footer: {
                Text("Rides are detected automatically. With routes on, the GPS track is recorded while you ride, including in the background.")
            }

            Section {
                NavigationLink {
                    SecuritySettingsView()
                } label: {
                    SettingsLabel(title: "Lock and PIN", symbol: "lock.fill")
                }
                NavigationLink {
                    DataSettingsView()
                } label: {
                    SettingsLabel(title: "Data and storage", symbol: "internaldrive.fill", tint: .gray)
                }
            }

            Section {
                NavigationLink {
                    InfoView()
                } label: {
                    SettingsLabel(title: "Scooter information", symbol: "info.circle.fill", tint: .gray)
                }
                NavigationLink {
                    DebugView()
                } label: {
                    SettingsLabel(title: "Debug", symbol: "ladybug.fill", tint: .gray)
                }
            } header: {
                Text("Advanced")
            } footer: {
                Text("Erup \(AppVersion.display)")
                    .frame(maxWidth: .infinity)
                    .padding(.top, 8)
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.large)
    }
}

/// The top row: the scooter and whether it is connected.
private struct ScooterSummaryRow: View {
    @Environment(ScooterStore.self) private var store
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10)) : AnyLayout(HStackLayout(spacing: 14))
        layout {
            SettingsIcon(symbol: "scooter", tint: .accentColor)
                .scaleEffect(1.25)
                .padding(5)
            VStack(alignment: .leading, spacing: 3) {
                Text("Scooter").font(.headline)
                HStack(spacing: 6) {
                    Circle().fill(store.connection.tint).frame(width: 8, height: 8)
                    Text(store.connection.title)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

struct RenameSheet: View {
    @Environment(ScooterStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var isSaving = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 0) {
                        Text(GATT.namePrefix).foregroundStyle(.secondary)
                        TextField("Name", text: $name)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                } footer: {
                    Text("The ZYD_ prefix is kept so the scooter stays findable. Use up to 12 letters, digits, dashes or underscores. The new name applies after the scooter restarts.")
                }
            }
            .navigationTitle("Rename")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        isSaving = true
                        Task {
                            let saved = await store.rename(suffix: name)
                            isSaving = false
                            if saved { dismiss() }
                        }
                    }
                    .disabled(name.isEmpty || isSaving)
                }
            }
        }
        .presentationDetents([.medium])
    }
}

struct PINChangeSheet: View {
    @Environment(ScooterStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var oldPIN = PINVault.pin ?? ""
    @State private var pin = ""
    @State private var confirmation = ""
    @State private var isSaving = false

    private func isSixDigits(_ text: String) -> Bool { text.count == 6 && text.allSatisfy(\.isNumber) }

    private var isValid: Bool {
        isSixDigits(oldPIN) && isSixDigits(pin) && pin == confirmation && pin != oldPIN
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("Current PIN", text: $oldPIN).keyboardType(.numberPad)
                } footer: {
                    Text("Erup checks the current PIN with the scooter before changing it. A wrong PIN may make the scooter drop the connection, so Erup tries only once.")
                }
                Section {
                    SecureField("New PIN (6 digits)", text: $pin).keyboardType(.numberPad)
                    SecureField("Repeat PIN", text: $confirmation).keyboardType(.numberPad)
                }
            }
            .navigationTitle("Change PIN")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        isSaving = true
                        Task {
                            let saved = await store.changePIN(from: oldPIN, to: pin)
                            isSaving = false
                            if saved { dismiss() }
                        }
                    }
                    .disabled(!isValid || isSaving)
                }
            }
        }
        .presentationDetents([.medium])
    }
}

struct LockPINSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var pin = PINVault.pin ?? ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("PIN (6 digits)", text: $pin).keyboardType(.numberPad)
                } footer: {
                    Text("Sent to the scooter before every lock and unlock, like the original app does. Stored on this phone only. A wrong PIN makes the scooter drop the connection, so leave it empty unless the scooter asks for one. New scooters use 888888.")
                }
            }
            .navigationTitle("PIN used for lock")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        PINVault.pin = pin.isEmpty ? nil : pin
                        dismiss()
                    }
                    .disabled(!(pin.isEmpty || (pin.count == 6 && pin.allSatisfy(\.isNumber))))
                }
            }
        }
        .presentationDetents([.medium])
    }
}

#Preview("Settings, light") {
    NavigationStack { SettingsView() }.environment(ScooterStore.preview())
}

#Preview("Settings, dark") {
    NavigationStack { SettingsView() }.environment(ScooterStore.preview()).preferredColorScheme(.dark)
}

struct ExportedFile: Identifiable {
    let id = UUID()
    let url: URL
}

/// The system share sheet for a file, so the export can go to Files, AirDrop or Mail.
struct ShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
