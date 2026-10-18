import ActivityKit
import SwiftUI
import WidgetKit

struct ScooterLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ScooterActivityAttributes.self) { context in
            LockScreenActivityView(state: context.state)
                .padding()
        } dynamicIsland: { context in
            let state = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    VStack(alignment: .leading) {
                        Text("\(displaySpeed(state))")
                            .font(.system(size: 40, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                        Text(state.usesMiles ? "mph" : "km/h").font(.caption).foregroundStyle(.secondary)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing) {
                        Text("\(state.batteryPercent)%")
                            .font(.system(.title2, design: .rounded, weight: .semibold))
                            .monospacedDigit()
                        Text(WidgetFormat.distance(state.rangeKm.map(Double.init), usesMiles: state.usesMiles))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(WidgetFormat.gearName(state.gearRaw)).font(.subheadline.weight(.medium))
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        Label(WidgetFormat.distance(state.tripKm, usesMiles: state.usesMiles) + " trip", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                        Spacer()
                        Label(state.headlightOn ? "Light on" : "Light off", systemImage: state.headlightOn ? "headlight.high.beam.fill" : "headlight.high.beam")
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
            } compactLeading: {
                Text("\(state.batteryPercent)%").monospacedDigit()
            } compactTrailing: {
                Text("\(displaySpeed(state))").monospacedDigit()
            } minimal: {
                BatteryRing(percent: state.batteryPercent)
            }
        }
    }

    private func displaySpeed(_ state: ScooterActivityAttributes.ContentState) -> Int {
        state.usesMiles ? Int((Double(state.speedKmh) / WidgetFormat.kilometresPerMile).rounded()) : state.speedKmh
    }
}

struct LockScreenActivityView: View {
    let state: ScooterActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 16) {
            BatteryRing(percent: state.batteryPercent)
                .frame(width: 52, height: 52)
            VStack(alignment: .leading, spacing: 2) {
                Text(state.isConnected ? "Riding" : "Disconnected").font(.headline)
                Text("\(WidgetFormat.gearName(state.gearRaw)) · \(WidgetFormat.distance(state.rangeKm.map(Double.init), usesMiles: state.usesMiles)) range")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(state.usesMiles ? Int((Double(state.speedKmh) / WidgetFormat.kilometresPerMile).rounded()) : state.speedKmh)")
                .font(.system(size: 44, weight: .semibold, design: .rounded))
                .monospacedDigit()
        }
    }
}

struct BatteryRing: View {
    let percent: Int

    var body: some View {
        ZStack {
            Circle().stroke(.secondary.opacity(0.3), lineWidth: 4)
            Circle()
                .trim(from: 0, to: Double(percent) / 100)
                .stroke(percent <= 15 ? Color.red : Color.green, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .accessibilityLabel("Battery")
        .accessibilityValue("\(percent) percent")
    }
}
