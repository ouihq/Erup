import Charts
import SwiftUI

/// Distance and speed statistics for the Rides page: totals for a period and a chart over time.
struct RideStatisticsCard: View {
    let records: [RideStatRecord]
    let units: Units

    private enum Metric: String, CaseIterable, Identifiable {
        case distance = "Distance"
        case topSpeed = "Top speed"
        var id: String { rawValue }
    }

    @State private var scope: StatsScope = .week
    @State private var metric: Metric = .distance
    @State private var selected: Date?

    private var stats: RideStatistics { RideStatistics.compute(records, scope: scope) }

    var body: some View {
        let stats = stats
        VStack(alignment: .leading, spacing: 14) {
            Picker("Period", selection: $scope) {
                ForEach(StatsScope.allCases) { Text($0.rawValue).tag($0) }
            }
            .adaptiveSegmentedStyle()

            VStack(spacing: 14) {
                AdaptiveStack(spacing: 14) {
                    StatCell(title: "Distance", value: format(units.distance(fromKm: stats.totalKm), digits: stats.totalKm >= 100 ? 0 : 1), unit: units.distanceLabel)
                    StatCell(title: "Rides", value: "\(stats.rides)", unit: "")
                    StatCell(title: "Time", value: Duration.seconds(stats.seconds).formatted(.time(pattern: .hourMinute)), unit: "h")
                }
                AdaptiveStack(spacing: 14) {
                    StatCell(title: "Top speed", value: format(units.speed(fromKmh: stats.topKmh), digits: 0), unit: units.speedLabel)
                    StatCell(title: "Average", value: format(units.speed(fromKmh: stats.averageKmh), digits: 0), unit: units.speedLabel)
                    StatCell(title: "Energy", value: stats.whPerKm.map { format(units.perDistance($0), digits: 0) } ?? "–", unit: "Wh/\(units.distanceLabel)")
                }
            }

            Picker("Chart", selection: $metric) {
                ForEach(Metric.allCases) { Text($0.rawValue).tag($0) }
            }
            .adaptiveSegmentedStyle()

            header(stats)
            chart(stats)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground(cornerRadius: 16)
        .onChange(of: scope) { selected = nil }
    }

    // MARK: Chart

    private func value(_ bucket: StatsBucket) -> Double {
        switch metric {
        case .distance: units.distance(fromKm: bucket.km)
        case .topSpeed: units.speed(fromKmh: bucket.maxKmh)
        }
    }

    private var tint: Color { .accentColor }
    private var unitLabel: String { metric == .distance ? units.distanceLabel : units.speedLabel }

    private func selectedBucket(_ stats: RideStatistics) -> StatsBucket? {
        guard let selected else { return nil }
        return stats.buckets.last { $0.start <= selected }
    }

    private func header(_ stats: RideStatistics) -> some View {
        let bucket = selectedBucket(stats)
        let shown = bucket.map(value) ?? (metric == .distance ? units.distance(fromKm: stats.totalKm) : units.speed(fromKmh: stats.topKmh))
        return HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(shown, format: .number.precision(.fractionLength(metric == .distance && shown < 100 ? 1 : 0)))
                .font(.system(.title2, design: .rounded, weight: .semibold))
                .monospacedDigit()
            Text(unitLabel).font(.subheadline).foregroundStyle(.secondary)
            Spacer()
            Text(bucket.map { title($0, component: stats.bucketComponent) } ?? (metric == .distance ? "Total" : "Best"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func title(_ bucket: StatsBucket, component: Calendar.Component) -> String {
        component == .month
            ? bucket.start.formatted(.dateTime.month(.wide).year())
            : bucket.start.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }

    private func chart(_ stats: RideStatistics) -> some View {
        let component = stats.bucketComponent
        let highlighted = selectedBucket(stats)?.start
        return Chart(stats.buckets) { bucket in
            BarMark(x: .value("Period", bucket.start, unit: component), y: .value(metric.rawValue, value(bucket)))
                .foregroundStyle(tint.opacity(highlighted == nil || highlighted == bucket.start ? 1 : 0.35))
                .cornerRadius(3)
        }
        .chartXSelection(value: $selected)
        .chartYScale(domain: 0...max(yTop(stats), 1))
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { _ in
                AxisGridLine().foregroundStyle(Color.gray.opacity(0.25))
                AxisValueLabel().foregroundStyle(.secondary)
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: component, count: axisStride(stats))) { _ in
                AxisValueLabel(format: component == .month ? .dateTime.month(.narrow) : (scope == .week ? .dateTime.weekday(.narrow) : .dateTime.day()))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(height: 150)
        .accessibilityChartDescriptor(StatsChartDescriptor(
            title: "\(metric.rawValue) by \(component == .month ? "month" : "day")",
            unit: unitLabel,
            points: stats.buckets.map { (label: title($0, component: component), value: value($0)) }
        ))
    }

    private func yTop(_ stats: RideStatistics) -> Double {
        (stats.buckets.map(value).max() ?? 0) * 1.15
    }

    private func axisStride(_ stats: RideStatistics) -> Int {
        switch scope {
        case .week, .year: 1
        case .month: 5
        case .all: max(1, stats.buckets.count / 8)
        }
    }

    private func format(_ number: Double, digits: Int) -> String {
        number.formatted(.number.precision(.fractionLength(digits)))
    }
}

/// Lets VoiceOver users hear and explore the statistics chart.
private struct StatsChartDescriptor: AXChartDescriptorRepresentable {
    let title: String
    let unit: String
    let points: [(label: String, value: Double)]

    func makeChartDescriptor() -> AXChartDescriptor {
        let top = max(points.map(\.value).max() ?? 1, 1)
        let xAxis = AXCategoricalDataAxisDescriptor(title: "Period", categoryOrder: points.map(\.label))
        let unit = unit
        let yAxis = AXNumericDataAxisDescriptor(
            title: unit, range: 0...top, gridlinePositions: [],
            valueDescriptionProvider: { "\(Int($0.rounded())) \(unit)" }
        )
        let series = AXDataSeriesDescriptor(
            name: title, isContinuous: false,
            dataPoints: points.map { AXDataPoint(x: $0.label, y: $0.value) }
        )
        return AXChartDescriptor(title: title, summary: nil, xAxis: xAxis, yAxis: yAxis, additionalAxes: [], series: [series])
    }
}
