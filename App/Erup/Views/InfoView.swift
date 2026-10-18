import SwiftUI

struct InfoView: View {
    @Environment(ScooterStore.self) private var store

    var body: some View {
        List {
            Section {
                if let readout = store.controllerReadout {
                    LabeledContent("Model", value: readout.info.model)
                    LabeledContent("Hardware", value: readout.info.hardware)
                    LabeledContent("Bootloader", value: readout.info.bootloader)
                    LabeledContent("Firmware", value: readout.info.firmware)
                    LabeledContent("Unique code", value: readout.info.uniqueCode)
                        .textSelection(.enabled)
                }
                Button {
                    Task { await store.readControllerInfo() }
                } label: {
                    HStack {
                        Text(store.controllerReadout == nil ? "Read controller info" : "Read again")
                        if store.isReadingController { Spacer(); ProgressView() }
                    }
                }
                .disabled(!store.connection.isConnected || store.isReadingController)
            } header: {
                Text("Controller")
            } footer: {
                Text("Reading pauses live data for about a second and is only allowed while the scooter is standing still.")
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
