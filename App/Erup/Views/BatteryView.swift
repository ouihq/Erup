import Charts
import ScooterAnalytics
import SwiftData
import SwiftUI

struct BatteryView: View {
    @Environment(ScooterStore.self) private var store
    @Query(BatteryView.rideDescriptor) private var rides: [Ride]
    /// Worked out when the rides change, so a new battery reading does not redo it.
    @State private var history = BatteryHistory.empty
    @AppStorage("useMiles") private var useMiles = false
    @AppStorage(RideRecorder.capacityKey) private var manualCapacityWh = 0.0

    private var units: Units { Units(useMiles: useMiles) }

    /// The rides without their samples and routes, which this page never reads.
    private static var rideDescriptor: FetchDescriptor<Ride> {
        var descriptor = FetchDescriptor<Ride>(sortBy: [SortDescriptor(\.startedAt, order: .reverse)])
        descriptor.propertiesToFetch = [\.id, \.startedAt, \.distanceKm, \.energyWh, \.batteryStart, \.batteryEnd, \.internalResistanceOhm]
        return descriptor
    }

    /// Changes whenever a ride is added, finished or extended by a joined ride.
    private var historyKey: [Double] {
        [Double(rides.count), rides.first?.distanceKm ?? 0, rides.first?.energyWh ?? 0]
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                nowCard
                usageCard
                efficiencyCard
                healthCard
                capacityCard
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Battery")
        .task(id: historyKey) { history = makeHistory() }
        .onChange(of: manualCapacityWh) {
            store.invalidateRideContext()
        }
    }

    private func makeHistory() -> BatteryHistory {
        BatteryHistory(entries: rides.map {
            .init(id: $0.id, startedAt: $0.startedAt, distanceKm: $0.distanceKm, energyWh: $0.energyWh,
                  batteryUsed: $0.batteryUsed, internalResistanceOhm: $0.internalResistanceOhm)
        })
    }

    // MARK: Now

    private var percent: Int? { store.batteryPercent }

    private var levelTint: Color {
        guard let percent else { return .gray }
        return percent <= 15 ? .red : percent <= 30 ? .yellow : Palette.battery
    }

    private var activity: String? {
        guard store.batteryIsLive, let current = store.telemetry1?.current else { return nil }
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
                if !store.batteryIsLive, let date = store.batteryDate, percent != nil {
                    VStack(alignment: .trailing, spacing: 0) {
                        Text("Last known").font(.footnote.weight(.medium))
                        Text(date, style: .relative).font(.caption2) + Text(" ago").font(.caption2)
                    }
                    .foregroundStyle(.secondary)
                } else if let activity {
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
                .opacity(store.batteryIsLive ? 1 : 0.6)
                .motionSafeAnimation(.smooth, value: percent)
            Divider()
            LazyVGrid(columns: [GridItem(.flexible(), alignment: .topLeading), GridItem(.flexible(), alignment: .topLeading)], spacing: 14) {
                fact("Range", rangeText)
                fact("Energy left", energyLeftText)
                fact(store.batteryIsLive ? "Voltage" : "Voltage (last)", voltageText)
                fact(timeTitle, timeText)
                fact("Level from voltage", voltageLevelText)
                fact("Last ride", lastRideText)
                fact("Pack capacity", store.rangeModel.map { "\(Int($0.capacityWh.rounded())) Wh" } ?? "Not yet")
            }
            if store.rangeKm == nil {
                note("Range appears after about 3 km of riding, once the app has learned how much energy you use.")
            }
        }
    }

    private var voltage: Double? { store.telemetry1?.voltage ?? store.lastBattery?.voltage }

    /// State of charge read off the cell voltage curve, after adding back the voltage lost to the load.
    /// Shown only while the current is small, because that is when the curve is trustworthy.
    private var voltageLevel: Double? {
        let terminal: Double, current: Double
        if store.batteryIsLive, let t = store.telemetry1 {
            terminal = t.voltage
            current = t.current
        } else if let last = store.lastBattery, let c = last.current {
            terminal = last.voltage
            current = c
        } else {
            return nil
        }
        guard abs(current) < 6 else { return nil }
        let open = BatteryModel.openCircuitVoltage(terminal: terminal, current: current, resistanceOhm: history.packResistanceOhm)
        return BatteryModel.stateOfCharge(openCircuitVoltage: open)
    }

    private var voltageLevelText: String {
        voltageLevel.map { "≈ \($0.formatted(.number.precision(.fractionLength(0)))) %" } ?? "Under load"
    }

    private var voltageText: String {
        voltage.map { "\($0.formatted(.number.precision(.fractionLength(1)))) V" } ?? "–"
    }

    /// Electrical power right now: positive while riding, negative while charging.
    private var power: Double? { store.batteryIsLive ? store.telemetry1?.power : nil }

    private var timeTitle: String {
        if let power, power < -15 { return "Full in" }
        return "Time left"
    }

    /// Hours of riding left at the current draw, or time to full while charging.
    private var timeText: String {
        guard let model = store.rangeModel, let percent, let power else { return "–" }
        let capacity = model.capacityWh
        if power < -15 {
            return duration(hours: BatteryModel.hoursToFull(percent: Double(percent), capacityWh: capacity, measuredWatts: -power))
        }
        guard power > 30 else { return "–" }
        return duration(hours: capacity * Double(percent) / 100 / power)
    }

    private func duration(hours: Double) -> String {
        let minutes = Int((hours * 60).rounded())
        return minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) min" : "\(minutes) min"
    }

    private var rangeText: String {
        guard let range = store.rangeKm else { return "Not yet" }
        func shown(_ km: Double) -> Int { Int(units.distance(fromKm: km).rounded()) }
        if let band = store.rangeBandKm, shown(band.lowerBound) < shown(band.upperBound) {
            return "\(shown(band.lowerBound))–\(shown(band.upperBound)) \(units.distanceLabel)"
        }
        return "\(shown(range)) \(units.distanceLabel)"
    }

    private var lastRideText: String {
        guard let ride = history.lastRide else { return "–" }
        return "−\(ride.batteryUsed)% · \(units.distance(fromKm: ride.distanceKm).formatted(.number.precision(.fractionLength(1)))) \(units.distanceLabel)"
    }

    private var energyLeftText: String {
        guard let model = store.rangeModel, let percent else { return "Not yet" }
        return "\(Int((model.capacityWh * Double(percent) / 100).rounded())) Wh"
    }

    // MARK: Efficiency

    private var consumption: BatteryHistory.Consumption? { history.consumption }

    @ViewBuilder
    private var efficiencyCard: some View {
        let measured = history.efficiency
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
                if let best = measured.map(\.whPerKm).min(), let worst = measured.map(\.whPerKm).max() {
                    HStack(spacing: 0) {
                        fact("Best ride", "\(Int(units.perDistance(best).rounded())) Wh/\(units.distanceLabel)")
                        fact("Worst ride", "\(Int(units.perDistance(worst).rounded())) Wh/\(units.distanceLabel)")
                    }
                }
                Text("Average of your last 10 rides. Lower is better.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if measured.count > 1 {
                    Chart {
                        ForEach(measured) { ride in
                            BarMark(x: .value("Date", ride.date), y: .value("Wh", units.perDistance(ride.whPerKm)), width: .fixed(12))
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

    private func deltaText(_ consumption: BatteryHistory.Consumption) -> (text: String, better: Bool)? {
        guard let previous = consumption.previous, previous > 0 else { return nil }
        let change = (consumption.current - previous) / previous * 100
        guard abs(change) >= 1 else { return ("Same as before", true) }
        let value = Int(abs(change).rounded())
        return change < 0 ? ("↓ \(value)% better than before", true) : ("↑ \(value)% more than before", false)
    }

    // MARK: Health

    private func capacityDetail(_ model: RangeModel) -> String {
        if model.isCapacityCalibrated { return "Learned from your rides" }
        return manualCapacityWh > 0 ? "Set by you" : "Rated capacity from the manual, until your rides show more"
    }

    private var resistances: [BatteryHistory.Resistance] { history.resistances }

    private var resistanceTrend: (label: String, detail: String, tint: Color)? {
        history.resistanceTrend.map { ($0.label, $0.detail, $0.fast ? .red : $0.rising ? .yellow : Palette.battery) }
    }

    private var healthCard: some View {
        card {
            title("Battery health", symbol: "heart.text.square.fill")
            if let model = store.rangeModel {
                row("Pack capacity", "\(Int(model.capacityWh.rounded())) Wh", detail: capacityDetail(model))
                if model.isCapacityCalibrated {
                    Divider()
                    let health = BatteryModel.stateOfHealth(capacityWh: model.capacityWh)
                    row("Capacity vs. new", "\(Int(min(health, 100).rounded())) %", detail: "Rated \(Int(BatteryModel.nominalCapacityWh)) Wh (36 V, 9.5 Ah)")
                }
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

    // MARK: Usage

    private var usageCard: some View {
        let cycles = store.rangeModel.map { history.totalEnergyWh / $0.capacityWh }
        return card {
            title("Usage", symbol: "chart.bar.fill")
            LazyVGrid(columns: [GridItem(.flexible(), alignment: .topLeading), GridItem(.flexible(), alignment: .topLeading)], spacing: 14) {
                fact("Last 30 days", "\(units.distance(fromKm: history.monthDistanceKm).formatted(.number.precision(.fractionLength(0)))) \(units.distanceLabel) · \(history.monthRides) rides")
                fact("Energy, 30 days", "\((history.monthEnergyWh / 1000).formatted(.number.precision(.fractionLength(2)))) kWh")
                fact("All rides", "\(history.rideCount) · \(units.distance(fromKm: history.totalDistanceKm).formatted(.number.precision(.fractionLength(0)))) \(units.distanceLabel)")
                fact("Energy, all time", "\((history.totalEnergyWh / 1000).formatted(.number.precision(.fractionLength(1)))) kWh")
                fact("Full charge cycles", cycles.map { "≈ \($0.formatted(.number.precision(.fractionLength(0))))" } ?? "Not yet")
                fact("Energy per 100 \(units.distanceLabel)", Self.energyPer100(distance: units.distance(fromKm: history.totalDistanceKm), energy: history.totalEnergyWh))
            }
            note("Charge cycles are the energy used so far divided by the pack capacity.")
        }
    }

    private static func energyPer100(distance: Double, energy: Double) -> String {
        guard distance > 0 else { return "–" }
        let kWh = energy / distance * 100 / 1000
        return "\(kWh.formatted(.number.precision(.fractionLength(1)))) kWh"
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
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 72)
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
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { _ in
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
