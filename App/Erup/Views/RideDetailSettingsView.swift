import SwiftUI

/// What the ride page shows and which phone sensors feed it.
struct RideDetailSettingsView: View {
    @AppStorage(MotionRecorder.enabledKey) private var recordsMotion = true
    @AppStorage(RideDisplaySettings.altitudeKey) private var recordsAltitude = true
    @AppStorage(RideDisplaySettings.roughnessKey) private var recordsRoughness = true
    @AppStorage(RideDisplaySettings.openKey) private var openCharts = ""

    private let charts = RideMetric.allCases.map { ($0.rawValue, $0.title) }
    private let extras = [("Temperature", "thermometer.medium"), ("Elevation", "mountain.2.fill"), ("Road roughness", "waveform")]

    var body: some View {
        Form {
            if MotionRecorder.isAvailable {
                Section {
                    Toggle(isOn: $recordsMotion) {
                        SettingsLabel(title: "Record phone sensors", symbol: "gyroscope", tint: .teal)
                    }
                    if recordsMotion {
                        Toggle(isOn: $recordsAltitude) {
                            SettingsLabel(title: "Climb and descent", symbol: "mountain.2.fill", tint: .cyan)
                        }
                        Toggle(isOn: $recordsRoughness) {
                            SettingsLabel(title: "Road roughness and cornering", symbol: "waveform", tint: .brown)
                        }
                    }
                } header: {
                    Text("Phone sensors")
                } footer: {
                    Text("Climb comes from the barometer; roughness and cornering from the motion sensors. Only one value per second is kept, never the raw readings. The phone can be in a pocket or on the handlebar. They apply from the next ride.")
                }
            }

            Section {
                ForEach(charts, id: \.0) { name, title in
                    Toggle(title, isOn: RideDisplaySettings.binding($openCharts, name: name))
                }
            } header: {
                Text("Charts")
            } footer: {
                Text("Every chart on a ride page starts folded to keep it short. Turn one on to have it open. Opening or folding a chart on a ride page changes the same choice.")
            }

            Section {
                ForEach(extras, id: \.0) { title, _ in
                    Toggle(title, isOn: RideDisplaySettings.binding($openCharts, name: title))
                }
            } header: {
                Text("Temperature and phone sensors")
            }
        }
        .navigationTitle("Ride details")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview("Ride details settings, dark") {
    NavigationStack { RideDetailSettingsView() }
        .preferredColorScheme(.dark)
}
