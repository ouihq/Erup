import ScooterProtocol
import SwiftUI

struct DebugView: View {
    @Environment(ScooterStore.self) private var store
    @AppStorage(FeatureFlags.lockFlagMeansLockedKey) private var lockFlagMeansLocked = false

    var body: some View {
        List {
            Section {
                Toggle("Lock bit set means locked", isOn: $lockFlagMeansLocked)
            } header: {
                Text("Unconfirmed features")
            } footer: {
                Text("Register bit 11 was 1 while the scooter was rideable, so by default a set bit means unlocked. The scooter's Bluetooth lock is not real security.")
            }

            Section("Register 0") {
                if let t = store.telemetry1 {
                    LabeledContent("Raw", value: String(format: "0x%04X", t.register0.rawValue))
                    Text(binary(t.register0.rawValue))
                        .font(.system(.footnote, design: .monospaced))
                    bitRow("Headlight (2)", t.register0.headlight)
                    bitRow("Boot mode (5)", t.register0.bootMode)
                    bitRow("Imperial (6)", t.register0.imperialUnits)
                    bitRow("Cruise (9)", t.register0.cruiseControl)
                    bitRow("Lock flag (11)", t.register0.lockFlag)
                    bitRow("Ambient (15)", t.register0.ambientLight)
                    LabeledContent("Unknown bits", value: String(format: "0x%04X", t.register0.unknownBits))
                    LabeledContent("Gear byte / bits", value: "\(t.gearRaw) / \(t.register0.gearBits)")
                    LabeledContent("Raw speed", value: "\(t.speedRaw)")
                } else {
                    Text("No telemetry yet").foregroundStyle(.secondary)
                }
            }

            Section("Frame 2") {
                if let t = store.telemetry2 {
                    LabeledContent("limitCruise", value: "\(t.limitCruise)")
                    LabeledContent("Caps eco/drive/sport", value: "\(t.caps.eco)/\(t.caps.comfort)/\(t.caps.sport) km/h")
                    LabeledContent("Flags", value: String(format: "0x%04X", t.flags))
                    LabeledContent("Speed scaling flag", value: t.speedScalingFlag ? "set" : "clear")
                    LabeledContent("Display model", value: t.displayModel.map { String(format: "0x%04X", $0) } ?? "none")
                    LabeledContent("Display firmware", value: t.displayFirmware ?? "none")
                } else {
                    Text("No frame 2 yet").foregroundStyle(.secondary)
                }
            }

            Section("Device") {
                LabeledContent("Bluetooth firmware", value: store.deviceInfo.firmwareRevision ?? "unknown")
                LabeledContent("System ID", value: store.deviceInfo.systemID ?? "unknown")
                Button("Forget this scooter", role: .destructive) {
                    Task {
                        await store.forgetScooter()
                    }
                }
            }

            Section {
                Toggle("Log frames", isOn: Bindable(store).isFrameLoggingEnabled)
                Button("Clear log") { store.clearLog() }
                ForEach(store.frameLog.reversed()) { entry in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(entry.direction.rawValue) \(entry.label)  \(entry.date.formatted(.dateTime.hour().minute().second()))")
                            .font(.caption.weight(.semibold))
                        Text(entry.bytes.hexString)
                            .font(.system(.caption2, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
            } header: {
                Text("Frame log")
            }
        }
        .navigationTitle("Debug")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func bitRow(_ title: String, _ value: Bool) -> some View {
        LabeledContent(title, value: value ? "1" : "0")
    }

    private func binary(_ value: UInt16) -> String {
        let digits = String(value, radix: 2)
        let padded = String(repeating: "0", count: 16 - digits.count) + digits
        return stride(from: 0, to: 16, by: 4).map { start in
            let from = padded.index(padded.startIndex, offsetBy: start)
            return String(padded[from..<padded.index(from, offsetBy: 4)])
        }.joined(separator: " ")
    }
}

#Preview("Debug, dark") {
    NavigationStack { DebugView() }
        .environment(ScooterStore.preview())
        .preferredColorScheme(.dark)
}
