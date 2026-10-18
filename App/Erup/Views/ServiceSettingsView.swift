import SwiftUI

/// A reminder to service the scooter after a set distance.
struct ServiceSettingsView: View {
    @Environment(ScooterStore.self) private var store
    @AppStorage("useMiles") private var useMiles = false
    @AppStorage(ServiceReminder.intervalKey) private var intervalKm = ServiceReminder.defaultIntervalKm
    @AppStorage(ServiceReminder.lastServiceKey) private var lastServiceKm = 0.0

    private var units: Units { Units(useMiles: useMiles) }

    var body: some View {
        Form {
            Section {
                Stepper(value: $intervalKm, in: 100...5000, step: 100) {
                    LabeledContent("Remind me every", value: "\(Int(units.distance(fromKm: intervalKm))) \(units.distanceLabel)")
                }
            } footer: {
                Text("Based on the scooter's total distance.")
            }

            if let total = store.telemetry1?.totalKm {
                let remaining = ServiceReminder(intervalKm: intervalKm, lastServiceKm: lastServiceKm).remainingKm(totalKm: total)
                Section {
                    LabeledContent(
                        remaining > 0 ? "Next service in" : "Service overdue by",
                        value: "\(Int(units.distance(fromKm: abs(remaining)))) \(units.distanceLabel)"
                    )
                    Button("Mark serviced now") { lastServiceKm = total }
                }
            } else {
                Section {
                    Text("Connect your scooter once to see when the next service is due.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Service reminder")
        .navigationBarTitleDisplayMode(.inline)
    }
}
