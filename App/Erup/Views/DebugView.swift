import ScooterProtocol
import SwiftUI

struct DebugView: View {
    @Environment(ScooterStore.self) private var store
    @AppStorage(FeatureFlags.lockFlagMeansLockedKey) private var lockFlagMeansLocked = false
    @AppStorage(FeatureFlags.pauseAutomaticReadsKey) private var pauseAutomaticReads = false

    @State private var events: [DiagnosticLog.Entry] = []
    @State private var copied = false

    var body: some View {
        List {
            diagnosticsSection

            Section {
                Toggle("Pause automatic reads", isOn: $pauseAutomaticReads)
            } header: {
                Text("Connection test")
            } footer: {
                Text("Erup normally reads settings and the lock state by itself after connecting. Turn this on to send nothing but keep-alives, leave the app open for a few minutes and export the diagnostics. If \"Scooter not responding\" stops, those reads were causing it. The lock state and settings then only load when you open their screens.")
            }

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

    private var report: DiagnosticReport {
        DiagnosticReport(
            header: DiagnosticReport.header(for: store),
            frames: store.isFrameLoggingEnabled
                ? store.frameLog.map { "\($0.date.formatted(.iso8601)) \($0.direction.rawValue) \($0.label) \($0.bytes.hexString)" }
                : []
        )
    }

    private var diagnosticsSection: some View {
        Section {
            ShareLink(item: report, preview: SharePreview("Erup diagnostics")) {
                Label("Export diagnostics", systemImage: "square.and.arrow.up")
            }
            Button {
                UIPasteboard.general.string = report.text
                copied = true
            } label: {
                Label(copied ? "Copied" : "Copy to clipboard", systemImage: copied ? "checkmark" : "doc.on.doc")
            }
            Button("Clear diagnostics", role: .destructive) {
                DiagnosticLog.shared.clear()
                refreshEvents()
            }
            if events.isEmpty {
                Text("Nothing logged yet").foregroundStyle(.secondary)
            }
            ForEach(events) { entry in
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(entry.category.rawValue) · \(entry.foreground ? "fg" : "bg") · \(entry.date.formatted(.dateTime.hour().minute().second()))")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(entry.category == .error ? .red : .secondary)
                    Text(entry.message)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
        } header: {
            Text("Diagnostics")
        } footer: {
            Text("Records connection changes, why a link ended, background transitions and rides, and keeps them after the app is closed. It never includes your PIN or the scooter's name. Send the export when something goes wrong.")
        }
        .task {
            // Refresh while the screen is open, so a reconnect shows up without leaving it.
            while !Task.isCancelled {
                refreshEvents()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func refreshEvents() {
        events = Array(DiagnosticLog.shared.snapshot.suffix(150).reversed())
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
