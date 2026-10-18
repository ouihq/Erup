import Charts
import SwiftData
import SwiftUI

struct BatteryView: View {
    @Environment(ScooterStore.self) private var store
    @Query(sort: \Ride.startedAt, order: .reverse) private var rides: [Ride]
    @AppStorage("useMiles") private var useMiles = false
    @AppStorage(RideRecorder.capacityKey) private var manualCapacityWh = 0.0

    private var units: Units { Units(useMiles: useMiles) }
    private var recent: [Ride] { Array(rides.prefix(30)) }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                nowCard
                efficiencyCard
                healthCard
                totalsCard
                capacityCard
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Battery")
        .onChange(of: manualCapacityWh) {
            store.invalidateRideContext()
        }
    }

    // MARK: Now

    private var percent: Int? { store.telemetry1?.batteryPercent }

    private var levelTint: Color {
        guard let percent else { return .gray }
        return percent <= 15 ? .red : percent <= 30 ? .orange : Palette.battery
    }

    private var activity: String? {
        guard let current = store.telemetry1?.current else { return nil }
        if current < -0.2 { return "Charging" }
        if current > 0.5 { return "In use" }
        return "Resting"
    }

    @ScaledMetric(relativeTo: .largeTitle) private var percentSize: CGFloat = 48

    private var nowCard: some View {
        card {
            HStack(alignment: .firstTextBaseline) {
                Text(percent.map { "\($0)%" } ?? "–")
                    .font(.system(size: percentSize, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText(value: Double(percent ?? 0)))
                Spacer()
                if let activity {
                    Text(activity)
                        .font(.footnote.weight(.medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(levelTint.opacity(0.15), in: Capsule())
                        .foregroundStyle(levelTint)
                }
            }
            ProgressView(value: Double(percent ?? 0), total: 100)
                .tint(levelTint)
                .motionSafeAnimation(.smooth, value: percent)
            HStack(alignment: .top, spacing: 0) {
                fact("Range", store.rangeKm.map { "\(Int(units.distance(fromKm: $0).rounded())) \(units.distanceLabel)" } ?? "Not yet")
                fact("Energy left", energyLeftText)
                fact("Last ride", lastRideText)
            }
            if store.rangeKm == nil {
                note("Range appears after about 3 km of riding, once the app has learned how much energy you use.")
            }
        }
    }

    private var lastRideText: String {
        guard let ride = rides.first else { return "–" }
        return "−\(ride.batteryUsed)% · \(units.distance(fromKm: ride.distanceKm).formatted(.number.precision(.fractionLength(1)))) \(units.distanceLabel)"
    }

    private var energyLeftText: String {
        guard let model = store.rangeModel, let percent else { return "Not yet" }
        return "\(Int((model.capacityWh * Double(percent) / 100).rounded())) Wh"
    }

    // MARK: Efficiency

    private struct Consumption {
        let current: Double
        let previous: Double?
    }

    private var consumption: Consumption? {
        let usable = rides.filter { $0.distanceKm >= 0.5 && $0.energyWh > 0 }
        func average(_ slice: ArraySlice<Ride>) -> Double? {
            let distance = slice.reduce(0) { $0 + $1.distanceKm }
            guard distance > 0 else { return nil }
            return slice.reduce(0) { $0 + $1.energyWh } / distance
        }
        guard let current = average(usable.prefix(10)) else { return nil }
        let older = usable.dropFirst(10).prefix(10)
        return Consumption(current: current, previous: older.count >= 3 ? average(older) : nil)
    }

    @ViewBuilder
    private var efficiencyCard: some View {
        let measured = recent.filter { $0.whPerKm != nil }.reversed() as [Ride]
        card {
            title("Efficiency", symbol: "leaf.fill")
            if let consumption {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(units.perDistance(consumption.current), format: .number.precision(.fractionLength(0)))
                        .font(.system(.largeTitle, design: .rounded, weight: .semibold))
                        .monospacedDigit()
                    Text("Wh/\(units.distanceLabel)").font(.subheadline).foregroundStyle(.secondary)
                    Spacer()
                    if let delta = deltaText(consumption) {
                        Text(delta.text)
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(delta.better ? Palette.battery : .red)
                    }
                }
                Text("Average of your last 10 rides. Lower is better.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if measured.count > 1 {
                    Chart {
                        ForEach(measured) { ride in
                            BarMark(x: .value("Date", ride.startedAt), y: .value("Wh", units.perDistance(ride.whPerKm ?? 0)), width: .fixed(12))
                                .foregroundStyle(LinearGradient(colors: [Palette.battery, Palette.battery.opacity(0.5)], startPoint: .top, endPoint: .bottom))
                                .clipShape(RoundedRectangle(cornerRadius: 3))
                        }
                        RuleMark(y: .value("Average", units.perDistance(consumption.current)))
                            .foregroundStyle(Color.gray.opacity(0.7))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    }
                    .batteryChartStyle()
                    .frame(height: 140)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Energy use per ride")
                    .accessibilityValue("Last \(measured.count) rides, latest \(Int(units.perDistance(measured.last?.whPerKm ?? 0).rounded())) watt hours per \(units.distanceLabel), average \(Int(units.perDistance(consumption.current).rounded()))")
                }
            } else {
                note("Ride at least 0.5 km to see how much energy you use per kilometre.")
            }
        }
    }

    private func deltaText(_ consumption: Consumption) -> (text: String, better: Bool)? {
        guard let previous = consumption.previous, previous > 0 else { return nil }
        let change = (consumption.current - previous) / previous * 100
        guard abs(change) >= 1 else { return ("Same as before", true) }
        let value = Int(abs(change).rounded())
        return change < 0 ? ("↓ \(value)% better than before", true) : ("↑ \(value)% more than before", false)
    }

    // MARK: Health

    private var resistances: [(date: Date, milliohm: Double)] {
        recent.reversed().compactMap { ride in
            ride.internalResistanceOhm.map { (ride.startedAt, $0 * 1000) }
        }
    }

    private var resistanceTrend: (label: String, detail: String, tint: Color)? {
        let values = resistances.map(\.milliohm)
        guard values.count >= 4 else { return nil }
        let half = values.count / 2
        let early = values.prefix(half).reduce(0, +) / Double(half)
        let late = values.suffix(half).reduce(0, +) / Double(half)
        let change = (late - early) / early * 100
        switch change {
        case ..<5: return ("Stable", "No meaningful change over your recorded rides.", Palette.battery)
        case ..<15: return ("Rising slowly", "A small rise is normal as a battery ages.", .orange)
        default: return ("Rising", "Resistance is climbing faster than usual. Check the battery if range is also dropping.", .red)
        }
    }

    private var healthCard: some View {
        card {
            title("Battery health", symbol: "heart.text.square.fill")
            if let model = store.rangeModel {
                row("Pack capacity", "\(Int(model.capacityWh.rounded())) Wh", detail: model.isCapacityCalibrated ? "Learned from your rides" : "Set by you")
            } else {
                row("Pack capacity", "Not yet", detail: "Learned after rides that use at least 10% of the battery")
            }
            Divider()
            if let latest = resistances.last, let trend = resistanceTrend {
                row("Resistance", "\(latest.milliohm.formatted(.number.precision(.fractionLength(0)))) mΩ", detail: "Lower is healthier")
                HStack(spacing: 8) {
                    Circle().fill(trend.tint).frame(width: 8, height: 8)
                    Text(trend.label).font(.subheadline.weight(.semibold))
                    Text(trend.detail).font(.footnote).foregroundStyle(.secondary)
                }
                resistanceChart
            } else if let latest = resistances.last {
                row("Resistance", "\(latest.milliohm.formatted(.number.precision(.fractionLength(0)))) mΩ", detail: "A trend appears after a few more rides")
            } else {
                note("Resistance is measured when you accelerate firmly right after standing still. It shows how stiff the battery is: it slowly rises as the pack ages.")
            }
        }
    }

    private var resistanceChart: some View {
        let values = resistances.map(\.milliohm)
        let low = values.min() ?? 0, high = values.max() ?? 1
        let pad = max((high - low) * 0.3, 1)
        let domain = max(0, low - pad)...(high + pad)
        return Chart {
            ForEach(Array(resistances.enumerated()), id: \.offset) { _, point in
                AreaMark(x: .value("Date", point.date), yStart: .value("Base", domain.lowerBound), yEnd: .value("mΩ", point.milliohm))
                    .foregroundStyle(LinearGradient(colors: [Palette.battery.opacity(0.28), Palette.battery.opacity(0.0)], startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Date", point.date), y: .value("mΩ", point.milliohm))
                    .foregroundStyle(Palette.battery)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    .interpolationMethod(.monotone)
                PointMark(x: .value("Date", point.date), y: .value("mΩ", point.milliohm))
                    .foregroundStyle(Palette.battery)
                    .symbolSize(30)
            }
        }
        .chartYScale(domain: domain)
        .batteryChartStyle()
        .frame(height: 120)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Battery resistance over time")
        .accessibilityValue("\(values.count) measurements, from \(Int(values.first ?? 0)) to \(Int(values.last ?? 0)) milliohm")
    }

    // MARK: Totals

    private var totalsCard: some View {
        let distance = rides.reduce(0) { $0 + $1.distanceKm }
        let energy = rides.reduce(0) { $0 + $1.energyWh }
        return card {
            title("All recorded rides", symbol: "sum")
            HStack(spacing: 0) {
                StatCell(title: "Rides", value: "\(rides.count)", unit: "")
                Divider().frame(height: 32)
                StatCell(title: "Distance", value: units.distance(fromKm: distance).formatted(.number.precision(.fractionLength(0))), unit: units.distanceLabel)
                Divider().frame(height: 32)
                StatCell(title: "Energy", value: (energy / 1000).formatted(.number.precision(.fractionLength(1))), unit: "kWh")
            }
        }
    }

    // MARK: Capacity

    private var capacityCard: some View {
        card {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Set pack capacity").font(.subheadline.weight(.medium))
                    Text("Optional. Enter the Wh value printed on the battery; 0 lets the app learn it. Pure Flex: 342 Wh (36 V, 9.5 Ah).")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                TextField("0", value: $manualCapacityWh, format: .number)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 64)
                    .textFieldStyle(.roundedBorder)
                Text("Wh").foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Building blocks

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) { content() }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardBackground(cornerRadius: 16)
    }

    /// Card headings are neutral with one green icon, so the page has a single accent colour.
    private func title(_ text: String, symbol: String) -> some View {
        Label {
            Text(text).foregroundStyle(.primary)
        } icon: {
            Image(systemName: symbol).foregroundStyle(Palette.battery)
        }
        .font(.subheadline.weight(.semibold))
    }

    private func fact(_ title: String, _ value: String, tint: Color? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.subheadline.weight(.semibold)).monospacedDigit().foregroundStyle(tint ?? .primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(_ title: String, _ value: String, detail: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline)
                Text(detail).font(.footnote).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Text(value).font(.system(.title3, design: .rounded, weight: .semibold)).monospacedDigit()
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.footnote).foregroundStyle(.secondary)
    }
}

private extension View {
    /// Shared look for the battery charts: light horizontal grid, no vertical grid, clipped plot.
    func batteryChartStyle() -> some View {
        self
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                    AxisTick()
                    AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                }
            }
            .chartYAxis {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { _ in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(Color.gray.opacity(0.35))
                    AxisValueLabel()
                }
            }
            .chartXScale(range: .plotDimension(padding: 14))
            .chartPlotStyle { $0.clipped() }
    }
}

#Preview("Battery, dark") {
    NavigationStack { BatteryView() }
        .environment(ScooterStore.preview())
        .modelContainer(Ride.previewContainer())
        .preferredColorScheme(.dark)
}
