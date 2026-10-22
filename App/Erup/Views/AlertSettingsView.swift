import SwiftUI

/// Where the scooter's alerts fire. "Off" silences one alert; nothing here changes what the scooter itself does.
struct AlertSettingsView: View {
    @AppStorage(AlertSettings.chargeCompleteKey) private var chargeComplete = true

    var body: some View {
        Form {
            Section {
                picker(AlertSettings.batteryLow, symbol: "battery.25percent", tint: .orange)
                picker(AlertSettings.batteryCritical, symbol: "battery.0percent", tint: .red)
            } header: {
                Text("Battery")
            } footer: {
                Text("An alert can fire again once the level has climbed 5 points above its limit.")
            }

            Section {
                picker(AlertSettings.controllerHot, symbol: "cpu.fill", tint: .red)
                picker(AlertSettings.motorHot, symbol: "gearshape.2.fill", tint: .red)
            } header: {
                Text("Temperature")
            } footer: {
                Text("Limits are conservative guesses, not manufacturer values. A temperature alert re-arms after a drop of 10 °C. The limits are also drawn on the temperature charts.")
            }

            Section {
                Toggle(isOn: $chargeComplete) {
                    SettingsLabel(title: "Charging complete", symbol: "bolt.badge.checkmark.fill", tint: .green)
                }
            } footer: {
                Text("Tells you when the battery is full and the scooter is still on the charger.")
            }
        }
        .navigationTitle("Alerts")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func picker(_ option: AlertSettings.Option, symbol: String, tint: Color) -> some View {
        AlertLimitPicker(option: option, symbol: symbol, tint: tint)
    }
}

private struct AlertLimitPicker: View {
    let option: AlertSettings.Option
    let symbol: String
    let tint: Color
    @State private var value: Int

    init(option: AlertSettings.Option, symbol: String, tint: Color) {
        self.option = option
        self.symbol = symbol
        self.tint = tint
        _value = State(initialValue: AlertSettings.value(option))
    }

    var body: some View {
        Picker(selection: $value) {
            ForEach(option.choices, id: \.self) { Text(AlertSettings.title(for: $0, in: option)).tag($0) }
        } label: {
            SettingsLabel(title: option.title, symbol: symbol, tint: tint)
        }
        .onChange(of: value) { _, new in UserDefaults.standard.set(new, forKey: option.key) }
    }
}

#Preview("Alert settings, dark") {
    NavigationStack { AlertSettingsView() }
        .preferredColorScheme(.dark)
}
