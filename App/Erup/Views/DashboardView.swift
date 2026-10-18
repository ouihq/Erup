import ScooterProtocol
import SwiftUI

struct DashboardView: View {
    @Environment(ScooterStore.self) private var store
    @AppStorage("useMiles") private var useMiles = false

    private var units: Units { Units(useMiles: useMiles) }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                if store.connection.isConnected {
                    StatusStrip()
                } else {
                    ConnectionCard(
                        state: store.connection,
                        searchingSince: store.searchingSince,
                        lastSeen: store.lastTelemetryDate
                    )
                }
                Speedometer(
                    isAvailable: store.connection.isConnected,
                    speed: units.speed(fromKmh: store.speedKmh),
                    maxSpeed: units.speed(fromKmh: store.speedometerMaxKmh),
                    unit: units.speedLabel,
                    limit: store.connection.isConnected ? store.gearLimitKmh.map(units.speed(fromKmh:)) : nil,
                    regenWatts: store.regenWatts,
                    recoveredWh: store.regenEnergyWh
                )
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                TripLine(units: units)
                GearPicker()
                ToggleRow()
                LiveChartsCard(units: units)
                    .unavailable(!store.connection.isConnected)
                ThermalCard()
                    .unavailable(!store.connection.isConnected)
                ServiceNotice(units: units)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .background(Color(.systemGroupedBackground))
    }
}

struct Speedometer: View {
    var isAvailable = true
    let speed: Double
    let maxSpeed: Double
    let unit: String
    var limit: Double?
    var regenWatts: Double = 0
    var recoveredWh: Double = 0

    private static let sweep = 2.0 / 3.0
    /// About a third of the Pure Flex's 900 W peak motor power; real regen on a hub motor stays well below it.
    private static let regenFullScaleWatts = 300.0

    private var regenFraction: Double { min(max(regenWatts / Self.regenFullScaleWatts, 0), 1) }
    @ScaledMetric(relativeTo: .largeTitle) private var lineWidth: CGFloat = 16
    @ScaledMetric(relativeTo: .largeTitle) private var diameter: CGFloat = 230
    @ScaledMetric(relativeTo: .largeTitle) private var speedFontSize: CGFloat = 76

    private var fraction: Double { min(max(speed / max(maxSpeed, 1), 0), 1) }

    var body: some View {
        ZStack {
            Circle()
                .trim(from: 0, to: Self.sweep)
                .stroke(Color.secondary.opacity(0.18), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(150))
            Circle()
                .trim(from: 0, to: Self.sweep * fraction)
                .stroke(
                    AngularGradient(
                        colors: [.green, .yellow, .orange],
                        center: .center,
                        startAngle: .degrees(0),
                        endAngle: .degrees(240)
                    ),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(150))
                .motionSafeAnimation(.smooth(duration: 0.25), value: fraction)
            // The gear only accelerates to this speed; the arc continues past it for downhill speed.
            if let limit {
                let position = min(max(limit / max(maxSpeed, 1), 0), 1)
                Circle()
                    .trim(from: max(0, Self.sweep * position - 0.004), to: min(Self.sweep, Self.sweep * position + 0.004))
                    .stroke(Color.primary.opacity(0.85), style: StrokeStyle(lineWidth: lineWidth + 8, lineCap: .butt))
                    .rotationEffect(.degrees(150))
                    .accessibilityHidden(true)
            }
            // Inner arc, like the recuperation gauge in a car: it fills while the brake feeds the battery.
            Circle()
                .trim(from: 0, to: Self.sweep)
                .stroke(Color.secondary.opacity(0.10), style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .rotationEffect(.degrees(150))
                .padding(lineWidth + 8)
            Circle()
                .trim(from: 0, to: Self.sweep * regenFraction)
                .stroke(Palette.battery, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .rotationEffect(.degrees(150))
                .padding(lineWidth + 8)
                .motionSafeAnimation(.smooth(duration: 0.25), value: regenFraction)
            VStack(spacing: 0) {
                Group {
                    if isAvailable {
                        Text(speed, format: .number.precision(.fractionLength(0)))
                            .contentTransition(.numericText(value: speed))
                    } else {
                        Text("–")
                    }
                }
                .font(.system(size: speedFontSize, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .minimumScaleFactor(0.5)
                .foregroundStyle(isAvailable ? Color.primary : Color.secondary)
                Text(isAvailable ? unit : "Not connected")
                    .font((isAvailable ? Font.title3 : Font.subheadline).weight(.medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .foregroundStyle(.secondary)
                regenLabel
                    .padding(.top, 4)
            }
            .offset(y: 8)
        }
        .padding(lineWidth / 2)
        .frame(width: diameter, height: diameter)
        .padding(.bottom, -24)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Speed")
        .accessibilityValue(accessibilitySummary)
    }

    private var accessibilitySummary: String {
        guard isAvailable else { return "Not connected" }
        var parts = ["\(Int(speed.rounded())) \(unit)"]
        if let limit { parts.append("gear limit \(Int(limit.rounded()))") }
        if regenWatts >= 5 { parts.append("regenerating \(Int(regenWatts.rounded())) watts") }
        return parts.joined(separator: ", ")
    }

    /// Shows the power being recovered while braking, or the total recovered so far once it has stopped.
    @ViewBuilder
    private var regenLabel: some View {
        if regenWatts >= 5 {
            Label("\(Int(regenWatts.rounded())) W", systemImage: "arrow.down.circle.fill")
                .font(.footnote.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(Palette.battery)
                .accessibilityLabel("Regenerating \(Int(regenWatts.rounded())) watts")
        } else if recoveredWh >= 0.05 {
            Text("Recovered \(recoveredWh.formatted(.number.precision(.fractionLength(1)))) Wh")
                .font(.footnote)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        } else {
            Text(" ").font(.footnote)
        }
    }
}

struct GearPicker: View {
    @Environment(ScooterStore.self) private var store

    var body: some View {
        Picker("Gear", selection: Binding(
            get: { store.gear ?? .eco },
            set: { store.setGear($0) }
        )) {
            ForEach(Gear.allCases, id: \.self) { gear in
                Text(gear.title).tag(gear)
            }
        }
        .adaptiveSegmentedStyle()
        .disabled(!store.isReady)
        .sensoryFeedback(.selection, trigger: store.gear)
        .accessibilityLabel("Gear")
    }
}

struct ToggleRow: View {
    @Environment(ScooterStore.self) private var store

    var body: some View {
        AdaptiveStack(spacing: 12) {
            ToggleTile(title: "Light", symbol: "headlight.high.beam.fill", isOn: store.headlightOn) {
                store.setHeadlight(!store.headlightOn)
            }
            ToggleTile(title: "Cruise", symbol: "gauge.with.dots.needle.67percent", isOn: store.cruiseOn) {
                store.setCruise(!store.cruiseOn)
            }
            ToggleTile(title: store.isLocked ? "Unlock" : "Lock", symbol: store.isLocked ? "lock.fill" : "lock.open.fill", isOn: store.isLocked) {
                let unlocking = store.isLocked
                Task {
                    if unlocking, !(await BiometricGate.authenticate(reason: "Unlock your scooter.")) { return }
                    store.setLocked(!unlocking)
                }
            }
        }
        .disabled(!store.isReady)
    }
}

struct ToggleTile: View {
    let title: String
    let symbol: String
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: symbol).font(.title2)
                Text(title).font(.caption.weight(.medium))
            }
            .frame(maxWidth: .infinity, minHeight: 64)
            .foregroundStyle(isOn ? Color.white : Color.primary)
            .background(isOn ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.regularMaterial), in: RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.impact(weight: .light), trigger: isOn)
        .accessibilityLabel(title)
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityAddTraits(.isToggle)
    }
}

/// Trip and odometer, kept close to the speedometer.
struct TripLine: View {
    @Environment(ScooterStore.self) private var store
    let units: Units

    var body: some View {
        let t = store.telemetry1
        AdaptiveStack(spacing: 8) {
            item("Trip", t?.tripKm, digits: 1)
            Text("·").foregroundStyle(.tertiary).accessibilityHidden(true)
            item("Total", t?.totalKm, digits: 1)
        }
        .font(.subheadline)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    private func item(_ title: String, _ km: Double?, digits: Int) -> some View {
        HStack(spacing: 4) {
            Text(title).foregroundStyle(.secondary)
            Text(km.map { units.distance(fromKm: $0).formatted(.number.precision(.fractionLength(digits))) } ?? "–")
                .fontWeight(.semibold)
                .monospacedDigit()
            Text(units.distanceLabel).foregroundStyle(.secondary)
        }
    }
}

struct StatCell: View {
    let title: String
    let value: String?
    let unit: String
    var tint: Color?

    var body: some View {
        VStack(spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value ?? "–")
                    .font(.system(.title3, design: .rounded, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(tint ?? .primary)
                Text(unit).font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(value.map { "\($0) \(unit)" } ?? "unknown")
    }
}

struct Metric: View {
    let title: String
    let value: String?
    let unit: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value ?? "–")
                    .font(.system(.title3, design: .rounded, weight: .semibold))
                    .monospacedDigit()
                Text(unit).font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .cardBackground(cornerRadius: 16)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(value.map { "\($0) \(unit)" } ?? "unknown")
    }
}

struct ServiceNotice: View {
    @Environment(ScooterStore.self) private var store
    @AppStorage(ServiceReminder.intervalKey) private var intervalKm = ServiceReminder.defaultIntervalKm
    @AppStorage(ServiceReminder.lastServiceKey) private var lastServiceKm = 0.0
    let units: Units

    var body: some View {
        if let total = store.telemetry1?.totalKm,
           ServiceReminder(intervalKm: intervalKm, lastServiceKm: lastServiceKm).isDue(totalKm: total) {
            Label("Service due. Check brakes, tyres and bolts.", systemImage: "wrench.and.screwdriver")
                .font(.footnote.weight(.medium))
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .cardBackground(cornerRadius: 14)
        }
    }
}

struct AlertBanner: View {
    @Environment(ScooterStore.self) private var store

    var body: some View {
        if let message = store.alertMessage {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.secondary)
                Text(message)
                    .font(.footnote.weight(.medium))
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    store.dismissAlert()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
            }
            .padding(.leading, 12)
            .padding(.vertical, 2)
            .padding(.trailing, 2)
            .cardBackground(cornerRadius: 14)
            .padding(.horizontal, 16)
            .transition(.move(edge: .top).combined(with: .opacity))
            .onAppear { AccessibilityNotification.Announcement(message).post() }
        }
    }
}

#Preview("Dashboard, light") {
    NavigationStack { DashboardView() }.environment(ScooterStore.preview())
}

#Preview("Dashboard, dark") {
    NavigationStack { DashboardView() }
        .environment(ScooterStore.preview(register: 0x8c06))
        .preferredColorScheme(.dark)
}

#Preview("Searching, dark") {
    NavigationStack { DashboardView() }
        .environment(ScooterStore.preview(connection: .searching(.outOfRange)))
        .preferredColorScheme(.dark)
}
