import SwiftUI

/// The alerts: each is a rule that watches one reading and has a colour. The ones that come with the app can be changed
/// and switched off; others can be added, such as a warning for the motor getting warm.
struct AlertSettingsView: View {
    @AppStorage(AlertSettings.chargeCompleteKey) private var chargeComplete = true
    @State private var center = AlertRuleCenter.shared
    @State private var editing: AlertRule?
    @State private var confirmsReset = false

    var body: some View {
        Form {
            Section {
                ForEach(center.rules) { rule in
                    row(rule)
                }
                .onDelete { offsets in
                    for index in offsets { center.delete(center.rules[index]) }
                }
                Button {
                    editing = AlertRule(name: "", metric: .speed, direction: .above, threshold: AlertMetric.speed.defaultThreshold)
                } label: {
                    Label("Add an alert…", systemImage: "plus.circle.fill")
                }
            } header: {
                Text("Alerts")
            } footer: {
                Text("The colour marks the battery indicator and the banner in the app: yellow is a warning, red is critical. An alert fires once and again only after the reading has moved back. Notifications are optional per alert.")
            }

            Section {
                Toggle(isOn: $chargeComplete) {
                    SettingsLabel(title: "Charging complete", symbol: "bolt.badge.checkmark.fill", tint: .green)
                }
            } footer: {
                Text("Tells you when the battery is full and the scooter is still on the charger.")
            }

            Section {
                Button("Restore the standard alerts…", role: .destructive) { confirmsReset = true }
            } footer: {
                Text("Puts the standard six back as they came: battery low at 20% (yellow) and critical at 10% (red), the controller warm at 70 °C and hot at 85 °C, the motor warm at 80 °C and hot at 100 °C. Alerts you added are removed.")
            }
        }
        .navigationTitle("Alerts")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editing) { rule in
            AlertRuleEditor(rule: rule, isNew: !center.rules.contains { $0.id == rule.id })
        }
        .confirmationDialog("Restore the standard alerts?", isPresented: $confirmsReset, titleVisibility: .visible) {
            Button("Restore", role: .destructive) { center.resetToDefaults() }
        }
    }

    private func row(_ rule: AlertRule) -> some View {
        HStack(spacing: 12) {
            Button {
                editing = rule
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: rule.metric.symbol)
                        .foregroundStyle(rule.severity.color)
                        .frame(width: 28, height: 28)
                        .background(rule.severity.color.opacity(0.16), in: RoundedRectangle(cornerRadius: 7))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(rule.name.isEmpty ? rule.metric.title : rule.name).foregroundStyle(.primary)
                        Text(rule.summary + (rule.notifies ? "" : " · no notification"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Toggle("", isOn: Binding(
                get: { rule.isEnabled },
                set: { var changed = rule; changed.isEnabled = $0; center.update(changed) }
            ))
            .labelsHidden()
        }
        .deleteDisabled(rule.isBuiltIn)
    }
}

/// One alert: what it watches, when it fires, its colour, and whether it also notifies.
struct AlertRuleEditor: View {
    @State var rule: AlertRule
    let isNew: Bool
    @Environment(\.dismiss) private var dismiss
    @AppStorage("useMiles") private var useMiles = false

    private var units: Units { Units(useMiles: useMiles) }
    private var center: AlertRuleCenter { .shared }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $rule.name, prompt: Text(rule.metric.title))
                    if !rule.isBuiltIn {
                        Picker("Watch", selection: $rule.metric) {
                            ForEach(AlertMetric.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
                        }
                        .onChange(of: rule.metric) { _, metric in rule.threshold = metric.defaultThreshold }
                    }
                } header: {
                    Text("Alert")
                }

                Section {
                    if !rule.isBuiltIn {
                        Picker("When it is", selection: $rule.direction) {
                            ForEach(AlertDirection.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                    }
                    ValueChooser(
                        title: rule.direction == .above ? "At or above" : "At or below",
                        unit: displayUnit,
                        value: threshold,
                        range: displayRange,
                        step: rule.metric.step,
                        presets: displayPresets
                    )
                } header: {
                    Text("Condition")
                } footer: {
                    Text(rule.summary + ".")
                }

                Section {
                    Picker("Colour", selection: $rule.severity) {
                        ForEach(AlertSeverity.allCases) { severity in
                            Label {
                                Text(severity.title)
                            } icon: {
                                Image(systemName: severity.symbol).foregroundStyle(severity.color)
                            }
                            .tag(severity)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                    Toggle("Send a notification", isOn: $rule.notifies)
                } header: {
                    Text("Colour and notification")
                } footer: {
                    Text("The colour is used for the battery indicator and the banner in the app. Turn the notification off to see the alert in the app only.")
                }

                if !isNew && !rule.isBuiltIn {
                    Section {
                        Button("Delete this alert", role: .destructive) {
                            center.delete(rule)
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle(isNew ? "New alert" : "Alert")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if rule.name.trimmingCharacters(in: .whitespaces).isEmpty { rule.name = rule.metric.title }
                        center.update(rule)
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.large])
    }

    /// Speed is kept in km/h and shown in the rider's unit; everything else is shown as it is stored.
    private var displayRange: ClosedRange<Double> {
        guard rule.metric == .speed else { return rule.metric.range }
        return units.speed(fromKmh: rule.metric.range.lowerBound).rounded(.up)...units.speed(fromKmh: rule.metric.range.upperBound).rounded(.down)
    }

    private var displayPresets: [Double] {
        guard rule.metric == .speed else { return rule.metric.presets }
        return rule.metric.presets.map { units.speed(fromKmh: $0).rounded() }
    }

    private var displayUnit: String {
        rule.metric == .speed ? units.speedLabel : rule.metric.unit
    }

    private var threshold: Binding<Double> {
        Binding(
            get: { rule.metric == .speed ? units.speed(fromKmh: rule.threshold).rounded() : rule.threshold },
            set: { rule.threshold = rule.metric == .speed ? ($0 / units.speed(fromKmh: 1)) : $0 }
        )
    }
}

#Preview("Alerts, dark") {
    NavigationStack { AlertSettingsView() }
        .preferredColorScheme(.dark)
}
