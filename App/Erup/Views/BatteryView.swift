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
    @State private var openCycle: Int?
    @State private var showsAllCycles = false

    private var units: Units { Units(useMiles: useMiles) }

    /// The rides without their samples and routes, which this page never reads.
    private static var rideDescriptor: FetchDescriptor<Ride> {
        var descriptor = FetchDescriptor<Ride>(sortBy: [SortDescriptor(\.startedAt, order: .reverse)])
        descriptor.propertiesToFetch = [\.id, \.startedAt, \.endedAt, \.distanceKm, \.energyWh, \.batteryStart, \.batteryEnd, \.maxSpeedKmh, \.regenWh, \.internalResistanceOhm]
        return descriptor
    }

    /// Changes whenever a ride is added, finished or extended by a joined ride.
    private var historyKey: [Double] {
        [Double(rides.count), rides.first?.distanceKm ?? 0, rides.first?.energyWh ?? 0, Double(rides.first?.batteryEnd ?? 0)]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                nowCard

                sectionHeader("Charges", "Every charge to the next, worked out from your rides")
                currentCycleCard
                if history.cycles.count > 1 { cycleChartCard }
                if history.cycles.count > 1 { earlierCyclesCard }

                sectionHeader("Efficiency")
                efficiencyCard

                sectionHeader("Battery health")
                healthCard

                sectionHeader("Usage")
                statCard(usageTiles)

                sectionHeader("Battery info")
                infoCard
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
            .init(id: $0.id, startedAt: $0.startedAt, endedAt: $0.endedAt, distanceKm: $0.distanceKm, energyWh: $0.energyWh,
                  batteryStart: $0.batteryStart, batteryEnd: $0.batteryEnd, maxSpeedKmh: $0.maxSpeedKmh, regenWh: $0.regenWh,
                  internalResistanceOhm: $0.internalResistanceOhm)
        })
    }

    // MARK: Now

    private var percent: Int? { store.batteryPercent }

    private var levelTint: Color {
        guard let percent else { return .gray }
        return AlertRuleCenter.shared.severity(for: .battery, value: Double(percent))?.color ?? Palette.battery
    }

    private var activity: String? {
        guard store.batteryIsLive, let current = store.telemetry1?.current else { return nil }
        if current < -0.2 { return "Charging" }
        if current > 0.5 { return "In use" }
        return "Resting"
    }

    @ScaledMetric(relativeTo: .largeTitle) private var percentSize: CGFloat = 52

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
            statCells(nowTiles)
            if store.rangeKm == nil {
                note("Range appears after about 3 km of riding, once the app has learned how much energy you use.")
            }
        }
    }

    private var nowTiles: [Tile] {
        [
            Tile(title: "Range", value: rangeText, note: store.rangeBandKm == nil ? "from your own rides" : "likely, from your rides",
                 symbol: "road.lanes", tint: Palette.battery),
            Tile(title: "Energy left", value: energyLeftText, note: store.rangeModel.map { "of a \(Int($0.capacityWh.rounded())) Wh pack" } ?? "learned from rides",
                 symbol: "bolt.fill", tint: Palette.power),
            Tile(title: timeTitle, value: timeText, note: timeNote, symbol: "clock.fill", tint: Palette.speed),
            Tile(title: store.batteryIsLive ? "Voltage" : "Voltage (last)", value: voltageText,
                 note: voltageLevel.map { "≈ \($0.formatted(.number.precision(.fractionLength(0)))) % by voltage" } ?? "level by voltage under load",
                 symbol: "waveform.path.ecg", tint: Palette.voltage),
        ]
    }

    private var timeNote: String {
        if let power, power < -15 { return "at the charging power now" }
        return power.map { $0 > 30 ? "at the current draw" : "appears while riding" } ?? "appears while riding"
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

    private var energyLeftText: String {
        guard let model = store.rangeModel, let percent else { return "Not yet" }
        return "\(Int((model.capacityWh * Double(percent) / 100).rounded())) Wh"
    }

    // MARK: Charges

    /// The newest cycle, or an empty one when the battery is clearly fuller than the last ride left it.
    private var chargedSinceLastRide: Bool {
        guard let last = history.cycles.last, let percent else { return false }
        return ChargeCycles.isChargedSinceLastRide(lastRideEnd: last.endPercent, currentPercent: percent)
    }

    @ViewBuilder
    private var currentCycleCard: some View {
        if let cycle = history.cycles.last {
            if chargedSinceLastRide {
                card {
                    HStack(spacing: 12) {
                        Image(systemName: "bolt.badge.checkmark.fill").font(.title2).foregroundStyle(Palette.battery)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Charged, not ridden yet").font(.subheadline.weight(.semibold))
                            Text("The last ride ended at \(cycle.endPercent)%, the battery is at \(percent ?? 0)% now. The next ride starts a new charge.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Since the last charge").font(.subheadline.weight(.medium)).foregroundStyle(.secondary).padding(.horizontal, 4)
                    statCard(cycleTiles(cycle))
                }
            }
        } else {
            card {
                note("Your charges show up here once you have ridden. A new charge is spotted when a ride starts with clearly more battery than the one before it ended with.")
            }
        }
    }

    private func cycleTiles(_ cycle: ChargeCycles.Cycle) -> [Tile] {
        var tiles = [
            Tile(title: "Distance", value: distanceText(cycle.distanceKm),
                 note: cycle.projectedRangeKm.map { "≈ \(distanceText($0)) on a full charge" } ?? "since the charge",
                 symbol: "road.lanes", tint: Palette.speed),
            Tile(title: "Battery used", value: "\(cycle.startPercent)% → \(cycle.endPercent)%", note: "\(cycle.usedPercent)% of the pack",
                 symbol: "battery.50percent", tint: Palette.battery),
            Tile(title: "Energy used", value: "\(Int(cycle.energyWh.rounded())) Wh",
                 note: cycle.whPerKm.map { "\(Int(units.perDistance($0).rounded())) Wh/\(units.distanceLabel)" } ?? "efficiency appears after 0.5 km",
                 symbol: "bolt.fill", tint: Palette.power),
            Tile(title: "Rides", value: "\(cycle.rideCount)", note: durationText(cycle.ridingTime) + " riding",
                 symbol: "figure.outdoor.cycle", tint: Palette.speed),
        ]
        if let regen = cycle.regenWh, regen >= 0.5 {
            tiles.append(Tile(title: "Recovered", value: "+\(regen.formatted(.number.precision(.fractionLength(1)))) Wh",
                              note: cycle.energyWh > 0 ? "\(Int((regen / cycle.energyWh * 100).rounded()))% of the energy used" : "by braking",
                              symbol: "leaf.arrow.circlepath", tint: Palette.battery, valueTint: Palette.battery))
            tiles.append(Tile(title: "Top speed", value: speedText(cycle.maxSpeedKmh), note: "in this charge", symbol: "gauge.with.needle.fill", tint: Palette.speed))
        }
        return tiles
    }

    private func distanceText(_ km: Double) -> String {
        "\(units.distance(fromKm: km).formatted(.number.precision(.fractionLength(km < 10 ? 1 : 0)))) \(units.distanceLabel)"
    }

    private func speedText(_ kmh: Double) -> String {
        "\(units.speed(fromKmh: kmh).formatted(.number.precision(.fractionLength(0)))) \(units.speedLabel)"
    }

    private func durationText(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded())
        return minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) min" : "\(minutes) min"
    }

    private var cycleChartCard: some View {
        let shown = Array(history.cycles.suffix(12))
        return card {
            title("Distance per charge", symbol: "chart.bar.fill")
            Chart {
                ForEach(shown) { cycle in
                    BarMark(x: .value("Charge", cycle.number), y: .value("Distance", units.distance(fromKm: cycle.distanceKm)), width: .fixed(14))
                        .foregroundStyle(cycle.number == history.cycles.last?.number
                                         ? AnyShapeStyle(Palette.battery)
                                         : AnyShapeStyle(LinearGradient(colors: [Palette.battery.opacity(0.75), Palette.battery.opacity(0.4)], startPoint: .top, endPoint: .bottom)))
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                }
            }
            .chartXAxis {
                AxisMarks(values: shown.map(\.number)) { value in
                    AxisValueLabel { if let number = value.as(Int.self) { Text("\(number)") } }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { _ in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(Color.gray.opacity(0.35))
                    AxisValueLabel()
                }
            }
            .chartXScale(domain: Double((shown.first?.number ?? 1) - 1)...Double((shown.last?.number ?? 1) + 1))
            .chartPlotStyle { $0.clipped() }
            .frame(height: 130)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Distance ridden on each charge")
            .accessibilityValue("Last \(shown.count) charges, the latest \(distanceText(shown.last?.distanceKm ?? 0))")
            note("\(units.distanceLabel) ridden between two charges, oldest on the left. The green bar is the charge you are on.")
        }
    }

    private var earlierCyclesCard: some View {
        let earlier = Array(history.cycles.dropLast().reversed())
        let visible = showsAllCycles ? earlier : Array(earlier.prefix(5))
        return VStack(spacing: 0) {
            ForEach(Array(visible.enumerated()), id: \.element.id) { index, cycle in
                if index > 0 { Divider().padding(.leading, 14) }
                cycleRow(cycle)
            }
            if earlier.count > 5 {
                Divider().padding(.leading, 14)
                Button {
                    withAnimation(.snappy) { showsAllCycles.toggle() }
                } label: {
                    Text(showsAllCycles ? "Show fewer" : "Show all \(earlier.count) earlier charges")
                        .font(.subheadline.weight(.medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .cardBackground(cornerRadius: 16)
    }

    private func cycleRow(_ cycle: ChargeCycles.Cycle) -> some View {
        let isOpen = openCycle == cycle.number
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.snappy) { openCycle = isOpen ? nil : cycle.number }
            } label: {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(cycleDates(cycle)).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                        Text("\(cycle.rideCount) \(cycle.rideCount == 1 ? "ride" : "rides") · \(distanceText(cycle.distanceKm))\(cycle.whPerKm.map { " · \(Int(units.perDistance($0).rounded())) Wh/\(units.distanceLabel)" } ?? "")")
                            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                    Spacer(minLength: 8)
                    Text("\(cycle.startPercent)% → \(cycle.endPercent)%")
                        .font(.footnote.weight(.medium)).monospacedDigit().foregroundStyle(.secondary)
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(isOpen ? "Expanded" : "Collapsed")

            if isOpen {
                statCells(cycleDetailTiles(cycle))
                    .padding(.horizontal, 14)
                    .padding(.bottom, 12)
            }
        }
    }

    private func cycleDetailTiles(_ cycle: ChargeCycles.Cycle) -> [Tile] {
        var tiles = [
            Tile(title: "Energy used", value: "\(Int(cycle.energyWh.rounded())) Wh", note: "\(cycle.usedPercent)% of the pack", symbol: "bolt.fill", tint: Palette.power),
            Tile(title: "Riding time", value: durationText(cycle.ridingTime), note: "\(cycle.rideCount) \(cycle.rideCount == 1 ? "ride" : "rides")", symbol: "clock.fill", tint: Palette.speed),
            Tile(title: "Top speed", value: speedText(cycle.maxSpeedKmh), note: "in this charge", symbol: "gauge.with.needle.fill", tint: Palette.speed),
        ]
        if let projected = cycle.projectedRangeKm {
            tiles.append(Tile(title: "Full-charge range", value: distanceText(projected), note: "worked out from this charge", symbol: "road.lanes", tint: Palette.battery))
        } else if let regen = cycle.regenWh, regen >= 0.5 {
            tiles.append(Tile(title: "Recovered", value: "+\(regen.formatted(.number.precision(.fractionLength(1)))) Wh", note: "by braking", symbol: "leaf.arrow.circlepath", tint: Palette.battery, valueTint: Palette.battery))
        }
        return tiles
    }

    private func cycleDates(_ cycle: ChargeCycles.Cycle) -> String {
        let calendar = Calendar.current
        let start = cycle.startedAt.formatted(.dateTime.day().month(.abbreviated))
        if calendar.isDate(cycle.startedAt, inSameDayAs: cycle.endedAt) { return start }
        return "\(start) – \(cycle.endedAt.formatted(.dateTime.day().month(.abbreviated)))"
    }

    // MARK: Efficiency

    private var consumption: BatteryHistory.Consumption? { history.consumption }

    @ViewBuilder
    private var efficiencyCard: some View {
        let measured = Array(history.efficiency.suffix(14))
        VStack(alignment: .leading, spacing: 0) {
            if let consumption {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(units.perDistance(consumption.current), format: .number.precision(.fractionLength(0)))
                            .font(.system(.largeTitle, design: .rounded, weight: .semibold))
                            .monospacedDigit()
                        Text("Wh/\(units.distanceLabel)").font(.subheadline).foregroundStyle(.secondary)
                        Spacer()
                        if let delta = deltaText(consumption) {
                            Text(delta.text)
                                .font(.footnote.weight(.medium))
                                .foregroundStyle(delta.better ? Palette.battery : .orange)
                        }
                    }
                    note("Energy per \(units.distanceLabel) over your last 10 rides. Lower means a longer range.")
                }
                .padding(14)
                if measured.count > 1 {
                    efficiencyChart(measured, average: units.perDistance(consumption.current))
                        .padding(.horizontal, 14)
                        .padding(.bottom, 14)
                }
                if let best = measured.map(\.whPerKm).min(), let worst = measured.map(\.whPerKm).max() {
                    Divider()
                    statCells([
                        Tile(title: "Best ride", value: "\(Int(units.perDistance(best).rounded())) Wh/\(units.distanceLabel)", note: "least energy", symbol: "arrow.down.circle.fill", tint: Palette.battery),
                        Tile(title: "Worst ride", value: "\(Int(units.perDistance(worst).rounded())) Wh/\(units.distanceLabel)", note: "most energy", symbol: "arrow.up.circle.fill", tint: .orange),
                    ])
                    .padding(.horizontal, 14)
                }
            } else {
                note("Ride at least 0.5 km to see how much energy you use per kilometre.").padding(14)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground(cornerRadius: 16)
    }

    /// One bar per ride, oldest first and evenly spaced. Bars under the average are green, bars over it orange.
    private func efficiencyChart(_ rides: [BatteryHistory.Efficiency], average: Double) -> some View {
        let values = rides.map { units.perDistance($0.whPerKm) }
        let top = (values.max() ?? average) * 1.15
        return VStack(alignment: .leading, spacing: 6) {
            Chart {
                ForEach(Array(rides.enumerated()), id: \.element.id) { index, ride in
                    let value = units.perDistance(ride.whPerKm)
                    BarMark(x: .value("Ride", Double(index)), y: .value("Wh", value), width: .fixed(14))
                        .foregroundStyle(value <= average ? Palette.battery : Color.orange)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                }
                RuleMark(y: .value("Average", average))
                    .foregroundStyle(Color.primary.opacity(0.55))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
            .chartXScale(domain: -0.6...(Double(rides.count) - 0.4))
            .chartYScale(domain: 0...top)
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { _ in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(Color.gray.opacity(0.35))
                    AxisValueLabel()
                }
            }
            .chartPlotStyle { $0.clipped() }
            .frame(height: 140)
            HStack {
                Text(rides.first?.date.formatted(.dateTime.day().month(.abbreviated)) ?? "")
                Spacer()
                Text("Wh/\(units.distanceLabel) per ride · dashed line is the average, \(Int(average.rounded()))").foregroundStyle(.tertiary).lineLimit(1).minimumScaleFactor(0.8)
                Spacer()
                Text(rides.last?.date.formatted(.dateTime.day().month(.abbreviated)) ?? "")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Energy use per ride")
        .accessibilityValue("Last \(rides.count) rides, latest \(Int(values.last?.rounded() ?? 0)) watt hours per \(units.distanceLabel), average \(Int(average.rounded()))")
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
        if model.isCapacityCalibrated {
            return model.calibrationCycles > 0 ? "learned from your last \(model.calibrationCycles) \(model.calibrationCycles == 1 ? "charge" : "charges")" : "learned from your rides"
        }
        return manualCapacityWh > 0 ? "set by you" : "rated, until your rides show more"
    }

    private var resistances: [BatteryHistory.Resistance] { history.resistances }

    private var resistanceTrend: (label: String, detail: String, tint: Color)? {
        history.resistanceTrend.map { ($0.label, $0.detail, $0.fast ? .red : $0.rising ? .yellow : Palette.battery) }
    }

    private var healthCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            capacityHeader.padding(14)
            Divider()
            resistanceSection.padding(14)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground(cornerRadius: 16)
    }

    /// The learned capacity next to the rating, as a ring that fills with how much of a new pack is left.
    private var capacityHeader: some View {
        let model = store.rangeModel
        let health = model.map { BatteryModel.stateOfHealth(capacityWh: $0.capacityWh) }
        let known = (model?.isCapacityCalibrated ?? false) && health != nil
        let status = health.map(Self.healthStatus)
        return HStack(spacing: 16) {
            ZStack {
                Circle().stroke(Color.gray.opacity(0.25), lineWidth: 9)
                Circle()
                    .trim(from: 0, to: known ? min(max((health ?? 0) / 100, 0), 1) : 0)
                    .stroke((status?.tint ?? Palette.battery).gradient, style: StrokeStyle(lineWidth: 9, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                VStack(spacing: 0) {
                    Text(known ? "\(Int(min(health ?? 0, 100).rounded()))%" : "–")
                        .font(.system(.title3, design: .rounded, weight: .semibold)).monospacedDigit()
                    Text("of new").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .frame(width: 84, height: 84)
            VStack(alignment: .leading, spacing: 3) {
                Text("Pack capacity").font(.footnote.weight(.medium)).foregroundStyle(.secondary)
                Text(model.map { "\(Int($0.capacityWh.rounded())) Wh" } ?? "Not yet")
                    .font(.system(.title2, design: .rounded, weight: .semibold)).monospacedDigit()
                if known, let status {
                    Label(status.label, systemImage: status.symbol).font(.footnote.weight(.semibold)).foregroundStyle(status.tint)
                }
                Text(model.map(capacityDetail) ?? "learned after a ride that uses 10% or more")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Pack capacity")
        .accessibilityValue("\(model.map { "\(Int($0.capacityWh.rounded())) watt hours" } ?? "not known yet"), \(known ? "\(Int(min(health ?? 0, 100).rounded())) percent of new" : "not measured")")
    }

    private static func healthStatus(_ health: Double) -> (label: String, symbol: String, tint: Color) {
        switch health {
        case 90...: ("Like new", "checkmark.seal.fill", Palette.battery)
        case 80..<90: ("Good", "checkmark.circle.fill", Palette.battery)
        case 70..<80: ("Ageing", "exclamationmark.circle.fill", .yellow)
        default: ("Worn", "exclamationmark.triangle.fill", .orange)
        }
    }

    private var resistanceSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Label {
                    Text("Internal resistance").font(.subheadline.weight(.semibold))
                } icon: {
                    Image(systemName: "waveform.path").foregroundStyle(resistanceTrend?.tint ?? Palette.battery)
                }
                Spacer()
                if let latest = resistances.last {
                    Text("\(latest.milliohm.formatted(.number.precision(.fractionLength(0)))) mΩ")
                        .font(.system(.title3, design: .rounded, weight: .semibold)).monospacedDigit()
                }
            }
            if let trend = resistanceTrend {
                Text(trend.label)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(trend.tint.opacity(0.16), in: Capsule())
                    .foregroundStyle(trend.tint)
                note(trend.detail)
            }
            if resistances.count > 1 { resistanceChart }
            if resistances.isEmpty {
                note("Measured when you accelerate firmly right after standing still. It shows how stiff the battery is and slowly rises as the pack ages. Lower is healthier.")
            } else if resistanceTrend == nil {
                note("A trend appears after a few more rides. Lower is healthier.")
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
            }
        }
        .chartYScale(domain: domain)
        .batteryChartStyle()
        .frame(height: 100)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Battery resistance over time")
        .accessibilityValue("\(values.count) measurements, from \(Int(values.first ?? 0)) to \(Int(values.last ?? 0)) milliohm")
    }

    // MARK: Usage

    private var usageTiles: [Tile] {
        let equivalents = store.rangeModel.map { history.totalEnergyWh / $0.capacityWh }
        return [
            Tile(title: "Last 30 days", value: distanceText(history.monthDistanceKm), note: "\(history.monthRides) \(history.monthRides == 1 ? "ride" : "rides")", symbol: "calendar", tint: Palette.speed),
            Tile(title: "Energy, 30 days", value: "\((history.monthEnergyWh / 1000).formatted(.number.precision(.fractionLength(2)))) kWh", note: "taken from the battery", symbol: "bolt.fill", tint: Palette.power),
            Tile(title: "All rides", value: distanceText(history.totalDistanceKm), note: "\(history.rideCount) \(history.rideCount == 1 ? "ride" : "rides")", symbol: "road.lanes", tint: Palette.speed),
            Tile(title: "Energy, all time", value: "\((history.totalEnergyWh / 1000).formatted(.number.precision(.fractionLength(1)))) kWh", note: "\(Self.energyPer100(distance: units.distance(fromKm: history.totalDistanceKm), energy: history.totalEnergyWh)) per 100 \(units.distanceLabel)", symbol: "bolt.horizontal.fill", tint: Palette.power),
            Tile(title: "Charges", value: "\(history.cycles.count)", note: "spotted from your rides", symbol: "bolt.badge.checkmark.fill", tint: Palette.battery),
            Tile(title: "Full charges", value: equivalents.map { "≈ \($0.formatted(.number.precision(.fractionLength(0))))" } ?? "Not yet", note: "energy ÷ capacity", symbol: "battery.100percent.bolt", tint: Palette.battery),
        ]
    }

    private static func energyPer100(distance: Double, energy: Double) -> String {
        guard distance > 0 else { return "–" }
        let kWh = energy / distance * 100 / 1000
        return "\(kWh.formatted(.number.precision(.fractionLength(1)))) kWh"
    }

    // MARK: Info

    private var infoCard: some View {
        let fullHours = BatteryModel.hoursToFull(percent: 0, capacityWh: BatteryModel.nominalCapacityWh)
        return VStack(spacing: 0) {
            infoRow("Pack", "36 V · 9.5 Ah · \(Int(BatteryModel.nominalCapacityWh)) Wh")
            Divider()
            infoRow("Cells", "10 in series, lithium-ion")
            Divider()
            infoRow("Charger", "42 V · 2 A · ≈ \(duration(hours: fullHours))")
            Divider()
            infoRow("Tracking since", history.cycles.first.map { $0.startedAt.formatted(date: .abbreviated, time: .omitted) } ?? "your first ride")
        }
        .padding(.horizontal, 14)
        .cardBackground(cornerRadius: 16)
    }

    private func infoRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value).font(.subheadline.weight(.medium)).multilineTextAlignment(.trailing)
        }
        .padding(.vertical, 12)
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

    private struct Tile: Identifiable {
        let title: String
        let value: String
        let note: String
        let symbol: String
        let tint: Color
        var valueTint: Color?
        var id: String { title }
    }

    /// Figures in two columns, divided by hairlines, with no boxes of their own, so a section reads as one card.
    private func statCells(_ tiles: [Tile]) -> some View {
        let rows = stride(from: 0, to: tiles.count, by: 2).map { Array(tiles[$0..<min($0 + 2, tiles.count)]) }
        return VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                if index > 0 { Divider() }
                HStack(alignment: .top, spacing: 0) {
                    cell(row[0])
                    if row.count > 1 {
                        Divider()
                        cell(row[1])
                    } else {
                        Spacer(minLength: 0).frame(maxWidth: .infinity)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func statCard(_ tiles: [Tile]) -> some View {
        statCells(tiles)
            .padding(.horizontal, 14)
            .cardBackground(cornerRadius: 16)
    }

    private func cell(_ tile: Tile) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: tile.symbol).font(.footnote.weight(.semibold)).foregroundStyle(tile.tint)
                Text(tile.title).font(.footnote.weight(.medium)).foregroundStyle(.secondary).lineLimit(1)
            }
            Text(tile.value)
                .font(.system(.title3, design: .rounded, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(tile.valueTint ?? .primary)
                .minimumScaleFactor(0.7)
                .lineLimit(1)
            Text(tile.note).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
        .padding(.vertical, 12)
        .padding(.leading, 0)
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tile.title)
        .accessibilityValue("\(tile.value), \(tile.note)")
    }

    private func sectionHeader(_ text: String, _ detail: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(text).font(.title3.weight(.semibold))
            if let detail { Text(detail).font(.footnote).foregroundStyle(.secondary) }
        }
        .padding(.top, 14)
        .padding(.horizontal, 4)
        .accessibilityAddTraits(.isHeader)
    }

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
