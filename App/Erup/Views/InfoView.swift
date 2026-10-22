import SwiftUI

struct InfoView: View {
    @Environment(ScooterStore.self) private var store

    var body: some View {
        List {
            Section {
                if let record = store.firmwareRecord {
                    LabeledContent("Model", value: record.model)
                    LabeledContent("Hardware", value: record.hardware)
                    LabeledContent("Bootloader", value: record.bootloader)
                    LabeledContent("Firmware", value: record.firmware)
                    LabeledContent("Unique code", value: record.uniqueCode)
                        .textSelection(.enabled)
                    LabeledContent("Last read", value: record.readAt.formatted(date: .abbreviated, time: .shortened))
                }
                Button {
                    Task { await store.readControllerInfo() }
                } label: {
                    HStack {
                        Text(store.firmwareRecord == nil ? "Read controller info" : "Read again")
                        if store.isReadingController { Spacer(); ProgressView() }
                    }
                }
                .disabled(!store.connection.isConnected || store.isReadingController)
            } header: {
                Text("Controller")
            } footer: {
                Text("Read only: Erup never changes the controller's software. Reading pauses live data for about a second and only works while the scooter is standing still. The result is saved and included in exports.")
            }

            if let readout = store.controllerReadout {
                Section {
                    if let bytes = readout.batteryBytes {
                        Text(bytes.hexString).font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
                    } else {
                        Text(readout.batteryNote ?? "No answer").foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Battery (raw)")
                } footer: {
                    Text("The battery record layout is unconfirmed, so the bytes are shown as received.")
                }
            }

            Section("Display") {
                LabeledContent("Model", value: store.telemetry2?.displayModel.map { String(format: "0x%04X", $0) } ?? "–")
                LabeledContent("Firmware", value: store.telemetry2?.displayFirmware ?? "–")
            }

            Section("Bluetooth module") {
                LabeledContent("Firmware", value: store.deviceInfo.firmwareRevision ?? "–")
                LabeledContent("System ID", value: store.deviceInfo.systemID ?? "–")
                    .textSelection(.enabled)
            }
        }
        .navigationTitle("Scooter info")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview("Info, dark") {
    NavigationStack { InfoView() }.environment(ScooterStore.preview()).preferredColorScheme(.dark)
}
