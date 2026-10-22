import Charts
import ScooterProtocol
import SwiftUI

/// Rolling chart of the live telemetry the store keeps, with a header showing the current value.
struct LiveChartsCard: View {
    enum Metric: String, CaseIterable, Identifiable {
        case speed = "Speed"
        case power = "Power"
        case battery = "Battery"
        case temperature = "Temp"

        var id: Self { self }
    }

    enum Range: Int, CaseIterable, Identifiable {
        case oneMinute = 60
        case fiveMinutes = 300
        case fifteenMinutes = 900

        var id: Self { self }

        var title: String {
            switch self {
            case .oneMinute: "1m"
            case .fiveMinutes: "5m"
            case .fifteenMinutes: "15m"
            }
        }

        var axisStride: Int {
            switch self {
            case .oneMinute: 20
            case .fiveMinutes: 60
            case .fifteenMinutes: 300
            }
        }
    }

    @Environment(ScooterStore.self) private var store
    let units: Units
    @State private var metric = Metric.speed
    @State private var range = Range.oneMinute

    /// Everything the chart needs, computed once per render from the history.
    private struct Series {
        let samples: [LiveSample]
        let values: [Double]
        let xDomain: ClosedRange<Date>
        let yDomain: ClosedRange<Double>
        let xTicks: [Date]
        let average: Double?
        let maximum: Double?
        let current: Double?
    }

    private static let maxPoints = 150

    var body: some View {
        let series = makeSeries()
        VStack(alignment: .leading, spacing: 12) {
            Picker("Chart", selection: $metric) {
                ForEach(Metric.allCases) { Text($0.rawValue).tag($0) }
            }
            .adaptiveSegmentedStyle()

            if metric != .power, metric != .temperature { header(series) }

            if metric == .power {
                ElectricalPanels(samples: series.samples, xDomain: series.xDomain, xTicks: series.xTicks)
            } else if metric == .temperature {
                TemperatureChart(
                    points: series.samples.enumerated().map { index, sample in
                        .init(x: sample.date, controller: Double(sample.controllerTemperature), motor: Double(sample.motorTemperature), id: index)
                    },
                    xDomain: series.xDomain, xTicks: series.xTicks,
                    xLabel: { relativeLabel(for: $0, end: series.xDomain.upperBound) }
                )
            } else {
            Chart {
                ForEach(Array(zip(series.samples, series.values)), id: \.0.id) { sample, value in
                    AreaMark(
                        x: .value("Time", sample.date),
                        yStart: .value("Base", series.yDomain.lowerBound),
                        yEnd: .value(metric.rawValue, value)
                    )
                    .foregroundStyle(areaStyle)
                    .interpolationMethod(.monotone)
                    LineMark(x: .value("Time", sample.date), y: .value(metric.rawValue, value))
                        .foregroundStyle(tint)
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                        .interpolationMethod(.monotone)
                }
                if let last = series.samples.last, let value = series.values.last {
                    PointMark(x: .value("Time", last.date), y: .value(metric.rawValue, value))
                        .foregroundStyle(tint)
                        .symbolSize(60)
                }
                if metric == .speed, let cap = gearCap {
                    RuleMark(y: .value("Mode limit", units.speed(fromKmh: cap)))
                        .foregroundStyle(Palette.speed.opacity(0.7))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                        .annotation(position: .top, alignment: .leading, spacing: 2, overflowResolution: .init(x: .fit, y: .fit)) {
                            Text("\(store.gear?.title ?? "") max \(Int(units.speed(fromKmh: cap).rounded()))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                }
            }
            .chartXScale(domain: series.xDomain)
            .chartYScale(domain: series.yDomain)
            .chartXAxis {
                AxisMarks(values: series.xTicks) { value in
                    AxisTick()
                    AxisValueLabel {
                        if let date = value.as(Date.self) { Text(relativeLabel(for: date, end: series.xDomain.upperBound)) }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { _ in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(Color.gray.opacity(0.35))
                    AxisValueLabel()
                }
            }
            .chartPlotStyle { $0.clipped() }
            .frame(height: 170)
            .clipped()
            .overlay {
                if series.samples.count < 2 {
                    Text("Waiting for data").font(.footnote).foregroundStyle(.secondary)
                }
            }
            .accessibilityLabel("\(metric.rawValue) over the last \(range.title)")
            }

            Picker("Range", selection: $range) {
                ForEach(Range.allCases) { Text($0.title).tag($0) }
            }
            .adaptiveSegmentedStyle()
        }
        .padding(14)
        .cardBackground(cornerRadius: 16)
    }

    // MARK: Header

    private func header(_ series: Series) -> some View {
        HStack(alignment: .firstTextBaseline) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(metric.rawValue).font(.subheadline).foregroundStyle(.secondary)
                Text(series.current.map(format) ?? "–")
                    .font(.system(.title, design: .rounded, weight: .semibold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text(unitLabel).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            if let average = series.average, let maximum = series.maximum {
                Text("Avg \(format(average)) · Max \(format(maximum))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }

    // MARK: Data

    private func makeSeries() -> Series {
        let history = store.liveHistory
        let end = history.last?.date ?? .now
        let cutoff = end.addingTimeInterval(-Double(range.rawValue))
        let start = history.firstIndex { $0.date >= cutoff } ?? history.endIndex
        let window = history[start...]

        let allValues = window.map(value(of:))
        let step = max(1, window.count / Self.maxPoints)
        var samples: [LiveSample] = []
        var values: [Double] = []
        for (offset, pair) in zip(window, allValues).enumerated() where offset % step == 0 || offset == window.count - 1 {
            samples.append(pair.0)
            values.append(pair.1)
        }

        let first = window.first?.date ?? end
        let lower = min(max(first, cutoff), end.addingTimeInterval(-10))
        let xDomain = lower...end
        let span = Int(end.timeIntervalSince(lower))
        let tickStep = min(range.axisStride, max(10, span / 3))
        let ticks = stride(from: 0, through: span, by: tickStep).map { end.addingTimeInterval(-Double($0)) }

        let maximum = allValues.max()
        let minimum = allValues.min()
        return Series(
            samples: samples,
            values: values,
            xDomain: xDomain,
            yDomain: yDomain(minimum: minimum, maximum: maximum),
            xTicks: ticks,
            average: allValues.isEmpty ? nil : allValues.reduce(0, +) / Double(allValues.count),
            maximum: maximum,
            current: history.last.map(value(of:))
        )
    }

    private func yDomain(minimum: Double?, maximum: Double?) -> ClosedRange<Double> {
        switch metric {
        case .speed:
            let cap = gearCap.map(units.speed(fromKmh:)) ?? 0
            return 0...max(cap, maximum ?? 0, 10) * 1.2
        case .power:
            return min(minimum ?? 0, 0)...max(maximum ?? 0, 300) * 1.15
        case .battery:
            let low = max(0, (minimum ?? 100) - 5)
            return (low > 90 ? 90 : low)...100
        case .temperature:
            return 0...100
        }
    }

    private func relativeLabel(for date: Date, end: Date) -> String {
        let seconds = Int(end.timeIntervalSince(date).rounded())
        if seconds <= 0 { return "Now" }
        return seconds % 60 == 0 ? "−\(seconds / 60)m" : "−\(seconds)s"
    }

    private var gearCap: Double? {
        guard let caps = store.telemetry2?.caps, let gear = store.gear else { return nil }
        switch gear {
        case .eco: return Double(caps.eco)
        case .comfort: return Double(caps.comfort)
        case .sport: return Double(caps.sport)
        }
    }

    private var unitLabel: String {
        switch metric {
        case .speed: units.speedLabel
        case .power: "W"
        case .battery: "%"
        case .temperature: "°C"
        }
    }

    private func format(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0)))
    }

    private var tint: Color {
        switch metric {
        case .speed: Palette.speed
        case .power: Palette.power
        case .battery: Palette.battery
        case .temperature: Palette.temperature
        }
    }

    private var areaStyle: LinearGradient {
        LinearGradient(colors: [tint.opacity(0.35), tint.opacity(0.02)], startPoint: .top, endPoint: .bottom)
    }

    private func value(of sample: LiveSample) -> Double {
        switch metric {
        case .speed: units.speed(fromKmh: sample.speedKmh)
        case .power: sample.powerWatts
        case .battery: Double(sample.batteryPercent)
        case .temperature: Double(max(sample.controllerTemperature, sample.motorTemperature))
        }
    }
}

/// Power, current and voltage on one shared time axis: three stacked panels, each with its own unit and scale.
/// Dragging across any panel shows all three values at that moment.
struct ElectricalPanels: View {
    let samples: [LiveSample]
    let xDomain: ClosedRange<Date>
    let xTicks: [Date]
    @State private var selection: Date?

    private struct Panel: Identifiable {
        let title: String
        let unit: String
        let tint: Color
        let value: (LiveSample) -> Double
        let digits: Int
        var id: String { title }
    }

    private let panels: [Panel] = [
        Panel(title: "Power", unit: "W", tint: Palette.power, value: { $0.powerWatts }, digits: 0),
        Panel(title: "Current", unit: "A", tint: Palette.current, value: { $0.current }, digits: 1),
        Panel(title: "Voltage", unit: "V", tint: Palette.voltage, value: { $0.voltage }, digits: 1),
    ]

    var body: some View {
        VStack(spacing: 8) {
            ForEach(Array(panels.enumerated()), id: \.element.id) { index, panel in
                if index > 0 { Divider().opacity(0.5) }
                panelView(panel, isLast: index == panels.count - 1)
            }
        }
    }

    private var shown: LiveSample? {
        guard let selection else { return samples.last }
        return samples.min { abs($0.date.timeIntervalSince(selection)) < abs($1.date.timeIntervalSince(selection)) }
    }

    private func panelView(_ panel: Panel, isLast: Bool) -> some View {
        let values = samples.map(panel.value)
        let low = values.min() ?? 0, high = values.max() ?? 1
        let pad = max((high - low) * 0.15, panel.unit == "V" ? 0.3 : 1)
        let domain: ClosedRange<Double> = panel.unit == "V" ? (low - pad)...(high + pad) : min(low - pad, 0)...(high + pad)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Circle().fill(panel.tint).frame(width: 8, height: 8)
                Text(panel.title).font(.subheadline).foregroundStyle(.secondary)
                if let shown {
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text(panel.value(shown), format: .number.precision(.fractionLength(panel.digits)))
                            .font(.system(.title3, design: .rounded, weight: .semibold))
                            .monospacedDigit()
                            .contentTransition(.numericText())
                        Text(panel.unit).font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.leading, 6)
                    if (panel.unit == "W" || panel.unit == "A"), panel.value(shown) < 0, shown.speedKmh > 2 {
                        RegenTag()
                    }
                }
                Spacer(minLength: 0)
            }
            Chart {
                ForEach(samples) { sample in
                    AreaMark(x: .value("Time", sample.date), yStart: .value("Base", domain.lowerBound), yEnd: .value(panel.title, panel.value(sample)))
                        .foregroundStyle(LinearGradient(colors: [panel.tint.opacity(0.22), panel.tint.opacity(0.0)], startPoint: .top, endPoint: .bottom))
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("Time", sample.date), y: .value(panel.title, panel.value(sample)))
                        .foregroundStyle(panel.tint)
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                        .interpolationMethod(.monotone)
                }
                if let selection {
                    RuleMark(x: .value("Selected", selection))
                        .foregroundStyle(Color.gray.opacity(0.6))
                        .lineStyle(StrokeStyle(lineWidth: 1))
                }
            }
            .chartXScale(domain: xDomain)
            .chartYScale(domain: domain)
            .chartXSelection(value: $selection)
            .chartXAxis {
                if isLast {
                    AxisMarks(values: xTicks) { value in
                        AxisTick()
                        AxisValueLabel {
                            if let date = value.as(Date.self) { Text(label(for: date)) }
                        }
                    }
                } else {
                    AxisMarks(values: xTicks) { _ in AxisTick() }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 2)) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(Color.gray.opacity(0.35))
                    AxisValueLabel {
                        if let number = value.as(Double.self) {
                            Text(number.formatted(.number.precision(.fractionLength(panel.unit == "V" ? 1 : 0))))
                                .font(.caption2)
                                .frame(width: 40, alignment: .trailing)
                        }
                    }
                }
            }
            .chartPlotStyle { $0.clipped() }
            .frame(height: isLast ? 96 : 72)
        }
    }

    private func label(for date: Date) -> String {
        let seconds = Int(xDomain.upperBound.timeIntervalSince(date).rounded())
        if seconds <= 0 { return "Now" }
        return seconds % 60 == 0 ? "−\(seconds / 60)m" : "−\(seconds)s"
    }
}

/// One-line connection and vehicle summary shown when the link is up. The three main chips share the width
/// and always keep their labels; the lock sits at the end as a small icon that is there in both states,
/// so nothing moves when the scooter is locked.
struct StatusStrip: View {
    @Environment(ScooterStore.self) private var store

    var body: some View {
        AdaptiveStack(spacing: 8) {
            chip("Connected", symbol: "antenna.radiowaves.left.and.right", tint: .green)
            if let percent = store.telemetry1?.batteryPercent {
                chip("\(percent)%", symbol: batterySymbol(percent), tint: batteryTint(percent))
            }
            if let gear = store.gear {
                chip(gear.title, symbol: "speedometer", tint: .accentColor)
            }
            lockChip
        }
        .motionSafeAnimation(.smooth(duration: 0.2), value: store.isLocked)
    }

    private var lockChip: some View {
        let locked = store.isLocked
        return Image(systemName: locked ? "lock.fill" : "lock.open.fill")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(locked ? Color.red : Color.secondary)
            .frame(width: 34, height: 32)
            .background(Capsule().fill((locked ? Color.red : Color.secondary).opacity(locked ? 0.16 : 0.10)))
            .overlay(Capsule().strokeBorder((locked ? Color.red : Color.secondary).opacity(0.25), lineWidth: 0.5))
            .contentTransition(.symbolEffect(.replace))
            .accessibilityLabel(locked ? "Locked" : "Unlocked")
    }

    private func batteryTint(_ percent: Int) -> Color {
        percent <= 15 ? .red : percent <= 30 ? .orange : .green
    }

    private func batterySymbol(_ percent: Int) -> String {
        switch percent {
        case ..<13: "battery.0percent"
        case ..<38: "battery.25percent"
        case ..<63: "battery.50percent"
        case ..<88: "battery.75percent"
        default: "battery.100percent"
        }
    }

    private func chip(_ text: String, symbol: String, tint: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(text).foregroundStyle(.primary)
        }
        .font(.footnote.weight(.semibold))
        .lineLimit(1)
        .minimumScaleFactor(0.85)
        .frame(maxWidth: .infinity)
        .frame(minHeight: 32)
        .background(Capsule().fill(tint.opacity(0.14)))
        .overlay(Capsule().strokeBorder(tint.opacity(0.28), lineWidth: 0.5))
    }
}

#Preview("Charts, dark") {
    ScrollView {
        VStack(spacing: 16) {
            StatusStrip()
            LiveChartsCard(units: Units(useMiles: false))
        }
        .padding()
    }
    .environment(ScooterStore.preview())
    .preferredColorScheme(.dark)
}
