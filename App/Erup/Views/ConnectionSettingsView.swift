import SwiftUI

/// How Erup keeps the Bluetooth link to the scooter going. The defaults suit most riders; these are for fine tuning,
/// for example when the scooter beeps too often.
struct ConnectionSettingsView: View {
    @AppStorage(BackgroundKeepAlive.storageKey) private var keepRunning = BackgroundKeepAlive.defaultEnabled
    @AppStorage(StallRecovery.storageKey) private var recovery = StallRecovery.defaultValue
    @AppStorage(FeatureFlags.forceWriteWithoutResponseKey) private var writeWithoutAcknowledgement = false
    @AppStorage(FeatureFlags.pauseAutomaticReadsKey) private var pauseAutomaticReads = false

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $keepRunning) {
                    SettingsLabel(title: "Stay connected with the screen off", symbol: "antenna.radiowaves.left.and.right", tint: .green)
                }
            } footer: {
                Text("Keeps Erup running while the scooter is connected, so speed, rides and keep-alives do not stop when the phone locks. It uses location (the blue indicator shows) and more battery. Without it iOS suspends the app within seconds of locking.")
            }

            Section {
                Picker("When data stops", selection: $recovery) {
                    ForEach(StallRecovery.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } header: {
                Text("When the scooter stops sending data")
            } footer: {
                Text(recovery.explanation)
            }

            Section {
                Toggle(isOn: Binding(get: { !writeWithoutAcknowledgement }, set: { writeWithoutAcknowledgement = !$0 })) {
                    SettingsLabel(title: "Wait for the scooter's answer", symbol: "checkmark.circle.fill", tint: .blue)
                }
                Toggle(isOn: Binding(get: { !pauseAutomaticReads }, set: { pauseAutomaticReads = !$0 })) {
                    SettingsLabel(title: "Read lock state and settings", symbol: "arrow.triangle.2.circlepath", tint: .gray)
                }
            } header: {
                Text("Talking to the scooter")
            } footer: {
                Text("Waiting for the scooter's answer to every message is how the official app does it and keeps the link steady. Turn it off to go back to fast writes if the connection behaves worse. Reading the lock state and settings happens by itself after connecting; turn it off to send nothing but keep-alives. They then load only when you open their screens.")
            }
        }
        .navigationTitle("Connection")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview("Connection settings, dark") {
    NavigationStack { ConnectionSettingsView() }
        .preferredColorScheme(.dark)
}
