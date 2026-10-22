import Charts
import ScooterAnalytics
import SwiftUI

/// Temperature and the phone's sensors for one ride, as collapsible rows. A collapsed row shows its title, a summary and
/// a small preview of the line; tapping it opens the full chart, so these extras don't lengthen the page.
struct RideExtras: View {
    let digest: RideDigest
    let units: Units
    /// Drawn inside the card that holds the ride's charts, with a divider above, instead of as a card of its own.
    var embedded = false
    @AppStorage(RideDisplaySettings.openKey) private var openExtras = ""

    private struct Row: Identifiable {
        let title: String
        let symbol: String
        let tint: Color
        let summary: String
        let preview: [([Double], Color)]
        let chart: AnyView
        var id: String { title }
    }

    private var rows: [Row] {
        var rows: [Row] = []
        if digest.hasTemperatures {
            let controller = digest.samples.compactMap(\.controllerTemperature)
            let motor = digest.samples.compactMap(\.motorTemperature)
            rows.append(Row(
                title: "Temperature", symbol: "thermometer.medium", tint: Palette.controllerTemperature,
                summary: "Peak \(controller.max() ?? 0)° · \(motor.max() ?? 0)°C",
                preview: [
                    (digest.drawn.compactMap { $0.controllerTemperature.map(Double.init) }, Palette.controllerTemperature),
                    (digest.drawn.compactMap { $0.motorTemperature.map(Double.init) }, Palette.motorTemperature),
                ],
                chart: AnyView(temperatureChart)
            ))
        }
        if digest.hasElevation {
            let unit = units.useMiles ? "ft" : "m"
            let scale = units.useMiles ? 3.28084 : 1.0
            let values: (RideSample) -> Double? = { $0.sensors?.altitudeMeters.map { $0 * scale } }
            rows.append(extraRow(
                title: "Elevation", symbol: "mountain.2.fill", tint: Palette.altitude, unit: unit, value: values, padding: 1,
                summary: digest.climbMeters.flatMap { climb in digest.descentMeters.map { "Climb \(format(climb * scale)) · descent \(format($0 * scale)) \(unit)" } } ?? ""
            ))
        }
        if digest.hasVibration {
            let average = digest.averageVibrationG.map { format($0 * 1000) } ?? "–"
            let peak = digest.peakG.map { $0.formatted(.number.precision(.fractionLength(2))) } ?? "–"
            rows.append(extraRow(
                title: "Road roughness", symbol: "waveform", tint: Palette.vibration, unit: "mg",
                value: { $0.sensors?.vibrationG.map { $0 * 1000 } }, padding: nil,
                summary: "Avg \(average) mg · hardest bump \(peak) g"
            ))
        }
        return rows
    }

    var body: some View {
        if !rows.isEmpty {
            VStack(spacing: 0) {
                if embedded { Divider().padding(.leading, 54) }
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    if index > 0 { Divider().padding(.leading, 54) }
                    section(row)
                }
            }
            .modifier(CardIf(isOn: !embedded))
        }
    }

    private func extraRow(
        title: String, symbol: String, tint: Color, unit: String, value: @escaping (RideSample) -> Double?, padding: Double?, summary: String
    ) -> Row {
        Row(
            title: title, symbol: symbol, tint: tint, summary: summary,
            preview: [(digest.drawn.compactMap(value), tint)],
            chart: AnyView(ExtraSeriesChart(title: title, tint: tint, digest: digest, value: value, padding: padding))
        )
    }

    private var temperatureChart: some View {
        let points = digest.drawn.enumerated().map {
            TemperatureChart<Double>.Point(
                x: $0.element.offset, controller: $0.element.controllerTemperature.map(Double.init),
                motor: $0.element.motorTemperature.map(Double.init), id: $0.offset
            )
        }
        let end = max(digest.samples.last?.offset ?? 60, 60)
        return TemperatureChart(
            points: points, xDomain: 0...end, xTicks: Array(stride(from: 0, through: end, by: max(end / 4, 1))),
            xLabel: { ExtraSeriesChart.timeLabel($0) }, height: 150
        )
    }

    private func section(_ row: Row) -> some View {
        let isOpen = RideDisplaySettings.members(of: openExtras).contains(row.id)
        return VStack(spacing: 0) {
            Button {
                withAnimation(.snappy) {
                    var open = RideDisplaySettings.members(of: openExtras)
                    if isOpen { open.remove(row.id) } else { open.insert(row.id) }
                    openExtras = RideDisplaySettings.list(from: open)
                }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: row.symbol).foregroundStyle(row.tint).frame(width: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                        Text(row.summary).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                    Spacer(minLength: 8)
                    if !isOpen { MiniLines(series: row.preview).frame(width: 64, height: 28) }
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(isOpen ? "Expanded" : "Collapsed")
            .accessibilityHint(isOpen ? "Hides the chart" : "Shows the chart")

            if isOpen {
                row.chart
                    .padding(.horizontal, 14)
                    .padding(.bottom, 14)
            }
        }
    }

    private func format(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0)))
    }
}

/// A tiny, axis-less version of one or more lines, shown next to a collapsed chart.
struct MiniLines: View {
    let series: [([Double], Color)]

    var body: some View {
        Chart {
            ForEach(Array(series.enumerated()), id: \.offset) { seriesIndex, entry in
                ForEach(Array(entry.0.enumerated()), id: \.offset) { index, value in
                    LineMark(x: .value("Time", index), y: .value("Value", value), series: .value("Series", seriesIndex))
                        .foregroundStyle(entry.1)
                        .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                        .interpolationMethod(.monotone)
                }
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartYScale(domain: .automatic(includesZero: false))
        .accessibilityHidden(true)
    }
}

/// One sensor line over the ride: tinted line over a soft gradient.
private struct ExtraSeriesChart: View {
    let title: String
    let tint: Color
    let digest: RideDigest
    let value: (RideSample) -> Double?
    /// Extra room above and below, or nil to start at zero.
    let padding: Double?

    static func timeLabel(_ seconds: Double) -> String {
        seconds < 60 ? "\(Int(seconds))s" : "\(Int((seconds / 60).rounded()))m"
    }

    var body: some View {
        let points = digest.drawn.compactMap { sample in value(sample).map { (sample.offset, $0) } }
        let values = points.map(\.1)
        let low = values.min() ?? 0, high = values.max() ?? 1
        let domain = padding.map { (low - $0)...(high + $0) } ?? 0...max(high, 1) * 1.15
        Chart {
            ForEach(points, id: \.0) { offset, value in
                AreaMark(x: .value("Time", offset), yStart: .value("Base", domain.lowerBound), yEnd: .value(title, value))
                    .foregroundStyle(LinearGradient(colors: [tint.opacity(0.35), tint.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Time", offset), y: .value(title, value))
                    .foregroundStyle(tint)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    .interpolationMethod(.monotone)
            }
        }
        .chartXScale(domain: 0...max(digest.samples.last?.offset ?? 60, 60))
        .chartYScale(domain: domain)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { value in
                AxisTick()
                AxisValueLabel {
                    if let seconds = value.as(Double.self) { Text(Self.timeLabel(seconds)) }
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
        .frame(height: 150)
        .clipped()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title) over the ride")
    }
}

private struct CardIf: ViewModifier {
    let isOn: Bool

    func body(content: Content) -> some View {
        if isOn { content.cardBackground(cornerRadius: 16) } else { content }
    }
}
