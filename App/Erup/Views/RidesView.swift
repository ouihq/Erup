import Charts
import MapKit
import ScooterAnalytics
import SwiftData
import SwiftUI

struct RidesView: View {
    @Environment(ScooterStore.self) private var store
    @Environment(\.modelContext) private var context
    @Query(sort: \Ride.startedAt, order: .reverse) private var rides: [Ride]
    @AppStorage("useMiles") private var useMiles = false

    private var units: Units { Units(useMiles: useMiles) }

    private var days: [(day: Date, rides: [Ride])] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: rides) { calendar.startOfDay(for: $0.startedAt) }
        return grouped.keys.sorted(by: >).map { ($0, grouped[$0] ?? []) }
    }

    private var statRecords: [RideStatRecord] {
        rides.map { RideStatRecord(date: $0.startedAt, km: $0.distanceKm, seconds: $0.duration, maxKmh: $0.maxSpeedKmh, wh: $0.energyWh) }
    }

    var body: some View {
        List {
            if !rides.isEmpty {
                Section {
                    RideStatisticsCard(records: statRecords, units: units)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
            }
            ForEach(days, id: \.day) { day in
                Section {
                    ForEach(day.rides) { ride in
                        NavigationLink {
                            RideDetailView(ride: ride)
                        } label: {
                            RideRow(ride: ride, units: units)
                        }
                    }
                    .onDelete { offsets in delete(offsets.map { day.rides[$0] }) }
                } header: {
                    dayHeader(day.day, rides: day.rides)
                }
            }
        }
        .overlay {
            if rides.isEmpty {
                ContentUnavailableView(
                    "No rides yet",
                    systemImage: "scooter",
                    description: Text("Rides are recorded automatically once you ride faster than 3 km/h for a few seconds.")
                )
            }
        }
        .navigationTitle("Rides")
    }

    private func dayHeader(_ day: Date, rides: [Ride]) -> some View {
        let distance = rides.reduce(0) { $0 + $1.distanceKm }
        return HStack {
            Text(dayTitle(day))
            Spacer()
            Text("\(rides.count) \(rides.count == 1 ? "ride" : "rides") · \(units.distance(fromKm: distance).formatted(.number.precision(.fractionLength(1)))) \(units.distanceLabel)")
                .font(.footnote)
                .monospacedDigit()
        }
    }

    private func dayTitle(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.wide).day().month(.abbreviated))
    }

    private func delete(_ doomed: [Ride]) {
        for ride in doomed { context.delete(ride) }
        do {
            try context.save()
        } catch {
            store.report("The ride could not be deleted: \(error.localizedDescription)")
        }
        store.invalidateRideContext()
    }
}

struct RideRow: View {
    let ride: Ride
    let units: Units

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 0) {
                Text(units.distance(fromKm: ride.distanceKm), format: .number.precision(.fractionLength(1)))
                    .font(.system(.title2, design: .rounded, weight: .semibold))
                    .monospacedDigit()
                Text(units.distanceLabel).font(.caption).foregroundStyle(.secondary)
            }
            .frame(minWidth: 52, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                Text("\(ride.startedAt.formatted(date: .omitted, time: .shortened)) · \(Duration.seconds(ride.duration).formatted(.time(pattern: .hourMinute))) h")
                    .font(.subheadline.weight(.medium))
                HStack(spacing: 10) {
                    Label("\(units.speed(fromKmh: ride.averageSpeedKmh).formatted(.number.precision(.fractionLength(0)))) \(units.speedLabel)", systemImage: "gauge.with.needle.fill")
                        .labelStyle(CompactLabelStyle())
                    if let whPerKm = ride.whPerKm {
                        Label("\(units.perDistance(whPerKm).formatted(.number.precision(.fractionLength(0)))) Wh/\(units.distanceLabel)", systemImage: "bolt.fill")
                            .labelStyle(CompactLabelStyle())
                    }
                    Label("\(ride.batteryUsed)%", systemImage: "battery.50percent")
                        .labelStyle(CompactLabelStyle())
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

private struct CompactLabelStyle: LabelStyle {
    var tint: Color = .secondary

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.imageScale(.small).foregroundStyle(tint)
            configuration.title
        }
    }
}

struct RideDetailView: View {
    let ride: Ride
    @AppStorage("useMiles") private var useMiles = false
    /// Decoded and prepared off the main thread, so opening a long ride never stalls the screen.
    @State private var detail: RideDetailData?
    /// The moment in the ride the rider is looking at, and the chart it belongs to. Only that chart draws the line.
    @State private var selectedOffset: TimeInterval?
    @State private var focusedMetric: RideMetric?
    @State private var markerIndex: Int?
    /// Charts the rider opened, remembered between rides. Everything starts folded.
    @AppStorage(RideDisplaySettings.openKey) private var openCharts = ""
    @ScaledMetric(relativeTo: .largeTitle) private var heroSize: CGFloat = 48

    private var units: Units { Units(useMiles: useMiles) }

    var body: some View {
        ScrollView {
            // Not lazy: a lazy stack re-measures rows as they appear, which moved the page under a finger on a chart.
            VStack(spacing: 16) {
                content
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .background(Color(.systemGroupedBackground))
        .task(id: ride.id) { await load() }
        .onChange(of: selectedOffset) { _, offset in updateMarker(offset) }
        .sensoryFeedback(.selection, trigger: focusedMetric)
        .navigationTitle(ride.startedAt.formatted(date: .abbreviated, time: .shortened))
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private var content: some View {
        if let route = detail?.route {
            RideMapView(route: route, markerIndex: markerIndex, topSpeedIndex: detail?.topSpeedRouteIndex, units: units, onSelect: selectedRoutePoint)
                .equatable()
                .frame(height: 300)
                .clipShape(RoundedRectangle(cornerRadius: 20))
        } else if let detail, detail.trackError == nil {
            noRouteCard
        }
        hero
        details(detail?.digest)
        if let detail {
            if let message = detail.samplesError {
                errorLabel("Charts unavailable: \(message)")
            } else if !detail.series.isEmpty {
                charts(detail)
            }
            if let message = detail.trackError { errorLabel("Route unavailable: \(message)") }
        } else {
            ProgressView().frame(maxWidth: .infinity).padding(.vertical, 40)
        }
    }

    private func load() async {
        // The model object stays on the main thread; only its stored data goes to the background.
        let samplesData = ride.samplesData
        let trackData = ride.trackData
        let startedAt = ride.startedAt
        detail = nil
        selectedOffset = nil
        focusedMetric = nil
        markerIndex = nil
        let prepared = await Task.detached(priority: .userInitiated) {
            RideDetailData.make(samplesData: samplesData, trackData: trackData, startedAt: startedAt)
        }.value
        guard !Task.isCancelled else { return }
        detail = prepared
    }

    /// A finger on a chart moves the shared moment and claims the line; lifting it lets both go.
    private func touched(_ metric: RideMetric, _ offset: TimeInterval?) {
        if let offset {
            selectedOffset = offset
            focusedMetric = metric
        } else if focusedMetric == metric {
            selectedOffset = nil
            focusedMetric = nil
        }
    }

    /// Tapping the route looks at that moment: the line appears on the speed chart.
    private func selectedRoutePoint(_ index: Int) {
        guard let route = detail?.route, route.dates.indices.contains(index) else { return }
        selectedOffset = max(0, route.dates[index].timeIntervalSince(ride.startedAt))
        focusedMetric = .speed
    }

    /// Moves the map marker only when the nearest route point actually changes, not on every touch event.
    private func updateMarker(_ offset: TimeInterval?) {
        guard let offset, let route = detail?.route,
              let index = RideInsights.nearestIndex(to: ride.startedAt.addingTimeInterval(offset), in: route.dates)
        else {
            markerIndex = nil
            return
        }
        if index != markerIndex { markerIndex = index }
    }

    // MARK: Energy recovered

    /// The exact amount measured while riding, or an estimate for rides recorded before that was measured.
    private var recovered: (wattHours: Double, isEstimate: Bool)? {
        guard let detail else { return nil }
        if let measured = ride.regenWh { return (measured, false) }
        return (detail.estimatedRegenWh, true)
    }

    private func recoveredText(_ value: (wattHours: Double, isEstimate: Bool)) -> String {
        "\(value.isEstimate ? "≈ " : "")+\(value.wattHours.formatted(.number.precision(.fractionLength(1)))) Wh"
    }

    // MARK: Cards

    private var hero: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(ride.startedAt.formatted(date: .omitted, time: .shortened)) – \(ride.endedAt.formatted(date: .omitted, time: .shortened))")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(units.distance(fromKm: ride.distanceKm), format: .number.precision(.fractionLength(2)))
                        .font(.system(size: heroSize, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text(units.distanceLabel).font(.title3.weight(.medium)).foregroundStyle(.secondary)
                }
            }
            AdaptiveStack(spacing: 14) {
                StatCell(title: "Time", value: Duration.seconds(ride.duration).formatted(.time(pattern: .hourMinuteSecond)), unit: "")
                StatCell(title: "Average", value: units.speed(fromKmh: ride.averageSpeedKmh).formatted(.number.precision(.fractionLength(1))), unit: units.speedLabel)
                StatCell(title: "Top speed", value: units.speed(fromKmh: ride.maxSpeedKmh).formatted(.number.precision(.fractionLength(1))), unit: units.speedLabel)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground(cornerRadius: 16)
    }

    private struct Tile: Identifiable {
        let title: String
        let value: String
        let note: String
        let symbol: String
        let tint: Color
        var valueTint: Color?
        var id: String { title }
    }

    private func tiles(_ digest: RideDigest?) -> [Tile] {
        var tiles = [
            Tile(title: "Energy used", value: "\(ride.energyWh.formatted(.number.precision(.fractionLength(1)))) Wh",
                 note: "from the battery", symbol: "bolt.fill", tint: Palette.power),
        ]
        if let recovered, recovered.wattHours >= 0.05 {
            let share = ride.energyWh > 0 ? Int((recovered.wattHours / ride.energyWh * 100).rounded()) : nil
            let note = share.map { "\(recovered.isEstimate ? "≈ " : "")\($0)% of energy used" } ?? "back from braking"
            tiles.append(Tile(title: "Recovered", value: recoveredText(recovered), note: note,
                              symbol: "leaf.arrow.circlepath", tint: Palette.battery, valueTint: Palette.battery))
        }
        tiles += [
            Tile(title: "Consumption",
                 value: ride.whPerKm.map { "\(units.perDistance($0).formatted(.number.precision(.fractionLength(0)))) Wh/\(units.distanceLabel)" } ?? "–",
                 note: "energy per \(units.distanceLabel)", symbol: "bolt.horizontal.fill", tint: Palette.power),
            Tile(title: "Battery", value: "\(ride.batteryStart)% → \(ride.batteryEnd)%",
                 note: "\(ride.batteryUsed)% used", symbol: "battery.50percent", tint: Palette.battery),
            Tile(title: "Controller", value: "\(ride.maxControllerTemperature)°C", note: "highest temperature",
                 symbol: "cpu.fill", tint: Palette.temperature),
            Tile(title: "Motor", value: "\(ride.maxMotorTemperature)°C", note: "highest temperature",
                 symbol: "gearshape.2.fill", tint: Palette.temperature),
        ]
        if let climb = digest?.climbMeters, let descent = digest?.descentMeters {
            tiles += [
                Tile(title: "Climb", value: elevation(climb), note: "total uphill", symbol: "arrow.up.right", tint: Palette.altitude),
                Tile(title: "Descent", value: elevation(descent), note: "total downhill", symbol: "arrow.down.right", tint: Palette.altitude),
            ]
        }
        return tiles
    }

    /// The ride's numbers as small cards, two to a row, each saying what it is and what it is measured against.
    private func details(_ digest: RideDigest?) -> some View {
        let all = tiles(digest)
        return Grid(horizontalSpacing: 10, verticalSpacing: 10) {
            ForEach(Array(stride(from: 0, to: all.count, by: 2)), id: \.self) { start in
                GridRow {
                    tile(all[start])
                    if start + 1 < all.count { tile(all[start + 1]) } else { Color.clear.gridCellUnsizedAxes([.horizontal, .vertical]) }
                }
            }
        }
    }

    private func tile(_ tile: Tile) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: tile.symbol).font(.footnote.weight(.semibold)).foregroundStyle(tile.tint)
                Text(tile.title).font(.footnote.weight(.medium)).foregroundStyle(.secondary)
            }
            Text(tile.value)
                .font(.system(.title3, design: .rounded, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(tile.valueTint ?? .primary)
                .minimumScaleFactor(0.7)
                .lineLimit(1)
            Text(tile.note).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground(cornerRadius: 14)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tile.title)
        .accessibilityValue("\(tile.value), \(tile.note)")
    }

    private func charts(_ detail: RideDetailData) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(detail.series.enumerated()), id: \.element.metric) { index, series in
                if index > 0 { Divider().padding(.leading, 54) }
                RideSeriesChart(
                    series: series,
                    unit: unit(for: series.metric),
                    scale: series.metric == .speed ? units.speed(fromKmh: 1) : 1,
                    // Only the chart being touched gets the moment, so the others are not redrawn while a finger moves.
                    selection: focusedMetric == series.metric ? selectedOffset : nil,
                    regen: series.metric == .power ? detail.regen : [],
                    recoveredText: series.metric == .power ? recovered.flatMap { $0.wattHours >= 0.05 ? recoveredText($0) : nil } : nil,
                    isExpanded: openMetrics.contains(series.metric.rawValue),
                    onToggle: { toggleChart(series.metric) },
                    onTouch: touched
                )
                .equatable()
            }
            RideExtras(digest: detail.digest, units: units, embedded: true)
        }
        .cardBackground(cornerRadius: 16)
    }

    private var openMetrics: Set<String> { RideDisplaySettings.members(of: openCharts) }

    private func toggleChart(_ metric: RideMetric) {
        var open = openMetrics
        let wasOpen = open.contains(metric.rawValue)
        if wasOpen { open.remove(metric.rawValue) } else { open.insert(metric.rawValue) }
        if wasOpen, focusedMetric == metric { selectedOffset = nil; focusedMetric = nil }
        withAnimation(.snappy) { openCharts = RideDisplaySettings.list(from: open) }
    }

    private func unit(for metric: RideMetric) -> String {
        switch metric {
        case .speed: units.speedLabel
        case .power: "W"
        case .voltage: "V"
        case .battery: "%"
        }
    }

    private func elevation(_ meters: Double) -> String {
        let value = units.useMiles ? meters * 3.28084 : meters
        return "\(value.formatted(.number.precision(.fractionLength(0)))) \(units.useMiles ? "ft" : "m")"
    }

    private func errorLabel(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle")
            .font(.footnote)
            .foregroundStyle(.secondary)
    }

    private var noRouteCard: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text("No route recorded").font(.subheadline.weight(.medium))
                Text("Turn on “Record route with GPS” in Settings to see a map of your next rides.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: "map").foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground(cornerRadius: 16)
    }
}

enum RideTime {
    /// "4:12" or "1:04:12", for a moment measured from the start of the ride.
    static func label(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        return total >= 3600
            ? String(format: "%d:%02d:%02d", total / 3600, total % 3600 / 60, total % 60)
            : String(format: "%d:%02d", total / 60, total % 60)
    }
}

extension RideMetric {
    var symbol: String {
        switch self {
        case .speed: "gauge.with.needle.fill"
        case .power: "bolt.fill"
        case .voltage: "waveform.path.ecg"
        case .battery: "battery.75percent"
        }
    }

    var tint: Color {
        switch self {
        case .speed: Palette.speed
        case .power: Palette.power
        case .voltage: Palette.voltage
        case .battery: Palette.battery
        }
    }
}

/// One ride metric drawn like the live dashboard chart. Touch and drag to move a line along the ride: the line, a dot
/// and a solid label with the reading appear on this chart only.
///
/// The view compares only what affects its drawing (the prepared series, units, and its own selection), so while a
/// finger moves on one chart the other three are not redrawn.
struct RideSeriesChart: View, Equatable {
    let series: RideSeries
    let unit: String
    /// Multiplies stored values for display (km/h to mph).
    let scale: Double
    /// The moment under the finger, only when it is on this chart.
    let selection: TimeInterval?
    /// Stretches where energy came back, shaded on the power chart.
    let regen: [RegenSegment]
    /// "+10.8 Wh" or "≈ +10.8 Wh" for the power chart.
    let recoveredText: String?
    var isExpanded = true
    var onToggle: () -> Void = {}
    let onTouch: (RideMetric, TimeInterval?) -> Void

    nonisolated static func == (lhs: RideSeriesChart, rhs: RideSeriesChart) -> Bool {
        lhs.series === rhs.series && lhs.unit == rhs.unit && lhs.scale == rhs.scale && lhs.selection == rhs.selection
            && lhs.regen == rhs.regen && lhs.recoveredText == rhs.recoveredText && lhs.isExpanded == rhs.isExpanded
    }

    private var metric: RideMetric { series.metric }
    private var tint: Color { metric.tint }
    /// Same height whether or not a finger is down, so the plot never moves under the finger.
    private static let headerHeight: CGFloat = 44

    var body: some View {
        let selected = selection.flatMap(series.sample(at:))
        VStack(alignment: .leading, spacing: 0) {
            headerRow(selected)
            if isExpanded {
                Group {
                    if series.isDrawable {
                        chart(selected)
                    } else {
                        Text("Not enough data for a chart")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 150)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 14)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(metric.title) over the ride")
        .accessibilityValue("Average \(format(series.average * scale)), maximum \(format(series.maximum * scale)) \(unit)")
    }

    private func chart(_ selected: RideSample?) -> some View {
        let domain = scaled(series.domain)
        return Chart {
            ForEach(regen, id: \.start) { segment in
                RectangleMark(
                    xStart: .value("Braking starts", segment.start),
                    xEnd: .value("Braking ends", segment.end),
                    yStart: .value("Low", domain.lowerBound),
                    yEnd: .value("High", domain.upperBound)
                )
                .foregroundStyle(Palette.battery.opacity(0.07))
            }
            if metric == .power, domain.lowerBound < 0 {
                RuleMark(y: .value("Zero", 0))
                    .foregroundStyle(Color.gray.opacity(0.6))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
            ForEach(series.drawn, id: \.offset) { point in
                AreaMark(
                    x: .value("Time", point.offset),
                    yStart: .value("Base", domain.lowerBound),
                    yEnd: .value(metric.title, point.value * scale)
                )
                .foregroundStyle(LinearGradient(colors: [tint.opacity(0.35), tint.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                .interpolationMethod(.monotone)
                LineMark(x: .value("Time", point.offset), y: .value(metric.title, point.value * scale))
                    .foregroundStyle(tint)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    .interpolationMethod(.monotone)
            }
            if let selected {
                // A dark halo under a bright core, so the line shows on any fill and in light and dark mode.
                RuleMark(x: .value("Selected", selected.offset))
                    .foregroundStyle(Color(.systemBackground).opacity(0.9))
                    .lineStyle(StrokeStyle(lineWidth: 6))
                RuleMark(x: .value("Selected", selected.offset))
                    .foregroundStyle(Color.primary)
                    .lineStyle(StrokeStyle(lineWidth: 2))
                PointMark(x: .value("Selected", selected.offset), y: .value(metric.title, metric.value(selected) * scale))
                    .symbol {
                        Circle().fill(tint).frame(width: 13, height: 13)
                            .overlay(Circle().stroke(Color.primary, lineWidth: 2.5))
                    }
                    .annotation(position: .top, spacing: 8, overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                        marker(selected)
                    }
            }
        }
        .chartXSelection(value: Binding(get: { selection }, set: { onTouch(metric, $0) }))
        .chartXScale(domain: 0...series.duration)
        .chartYScale(domain: domain)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { value in
                AxisTick()
                AxisValueLabel {
                    if let seconds = value.as(Double.self) { Text(timeLabel(seconds)) }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { _ in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(Color.gray.opacity(0.35))
                AxisValueLabel()
            }
        }
        .chartPlotStyle { $0.clipped() }
        .frame(height: 150)
    }

    // MARK: Header and label

    /// The power that is coming back at this moment, taken from the recorded reading with the same rule the dashboard uses.
    private func recoveredWatts(_ sample: RideSample) -> Double? {
        guard metric == .power else { return nil }
        let watts = RegenDetection.recoveredWatts(powerWatts: sample.powerWatts, speedKmh: sample.speedKmh)
        return watts > 0 ? watts : nil
    }

    private var chevron: some View {
        Image(systemName: "chevron.right")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.tertiary)
            .rotationEffect(.degrees(isExpanded ? 90 : 0))
    }

    /// One row for open and folded alike, so the whole width is the button: icon, name, average and maximum, then either the
    /// reading under the finger or a small preview of the line.
    private func headerRow(_ selected: RideSample?) -> some View {
        Button(action: onToggle) {
            HStack(spacing: 12) {
                Image(systemName: metric.symbol).foregroundStyle(tint).frame(width: 28)
                let scrubbing = isExpanded && selected != nil
                VStack(alignment: .leading, spacing: 2) {
                    Text(metric.title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary).lineLimit(1)
                    // While a finger is down the reading needs the room, so the summary steps aside.
                    if !scrubbing {
                        Text("Avg \(format(series.average * scale)) · Max \(format(series.maximum * scale)) \(unit)")
                            .font(.caption).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
                        if let recoveredText {
                            Text("Recovery \(recoveredText)")
                                .font(.caption2).foregroundStyle(Palette.battery).monospacedDigit().lineLimit(1)
                        }
                    }
                }
                .layoutPriority(0)
                Spacer(minLength: 8)
                if isExpanded {
                    if let selected { reading(selected).fixedSize().layoutPriority(1) }
                } else {
                    MiniLines(series: [(series.drawn.map { $0.value * scale }, tint)]).frame(width: 64, height: 28)
                }
                chevron
            }
            // Same height whether or not a finger is down, so the plot never moves under the finger.
            .frame(minHeight: Self.headerHeight)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
        .accessibilityHint(isExpanded ? "Hides the chart" : "Shows the chart")
    }

    private func reading(_ selected: RideSample) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            // While braking the power is negative; the amount coming back is shown, not a minus sign.
            Text(recoveredWatts(selected) ?? metric.value(selected) * scale, format: .number.precision(.fractionLength(metric.digits)))
                .font(.system(.title3, design: .rounded, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(tint)
            Text(unit).font(.caption).foregroundStyle(.secondary)
            if recoveredWatts(selected) != nil { RegenTag() }
            Text("at \(RideTime.label(selected.offset))").font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
    }

    /// The reading at the line, on the chart itself: solid, so it stays readable over the drawing underneath.
    private func marker(_ sample: RideSample) -> some View {
        let watts = recoveredWatts(sample)
        let text = watts.map { "Regen \(format($0)) W" }
            ?? "\(format(metric.value(sample) * scale, digits: metric.digits)) \(unit)"
        return Text(text)
            .font(.caption.weight(.bold))
            .monospacedDigit()
            .foregroundStyle(watts == nil ? tint : Palette.battery)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color(.secondarySystemBackground), in: Capsule())
            .overlay(Capsule().stroke(watts == nil ? tint : Palette.battery, lineWidth: 1))
    }

    private func scaled(_ range: ClosedRange<Double>) -> ClosedRange<Double> {
        (range.lowerBound * scale)...(range.upperBound * scale)
    }

    private func timeLabel(_ seconds: Double) -> String {
        seconds < 60 ? "\(Int(seconds))s" : "\(Int((seconds / 60).rounded()))m"
    }

    private func format(_ value: Double, digits: Int = 0) -> String {
        value.formatted(.number.precision(.fractionLength(digits)))
    }
}

#Preview("Rides, light") {
    NavigationStack { RidesView() }
        .environment(ScooterStore.preview())
        .modelContainer(Ride.previewContainer())
}

#Preview("Rides, dark") {
    NavigationStack { RidesView() }
        .environment(ScooterStore.preview())
        .modelContainer(Ride.previewContainer())
        .preferredColorScheme(.dark)
}
