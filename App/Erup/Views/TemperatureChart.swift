import Charts
import SwiftUI

/// Controller and motor temperature on one time axis, with the alert thresholds as dashed rules once the readings approach them.
/// Used for the live dashboard (dates on the x axis) and for finished rides (seconds since the start).
struct TemperatureChart<X: Plottable & Comparable>: View {
    struct Point: Identifiable {
        let x: X
        let controller: Double?
        let motor: Double?
        var id: Int
    }

    let points: [Point]
    let xDomain: ClosedRange<X>
    let xTicks: [X]
    let xLabel: (X) -> String
    var height: CGFloat = 170

    @State private var selection: X?

    var body: some View {
        let controller = points.compactMap(\.controller)
        let motor = points.compactMap(\.motor)
        let all = controller + motor
        let low = all.min() ?? 20
        let high = all.max() ?? 60
        let domain = max(0, min(low, 25) - 5)...max(high + 5, 60)
        let shown = nearestPoint()
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 16) {
                legend("Controller", Palette.controllerTemperature, value: shown?.controller)
                legend("Motor", Palette.motorTemperature, value: shown?.motor)
                Spacer(minLength: 0)
            }
            Chart {
                ForEach(points) { point in
                    if let value = point.controller {
                        LineMark(x: .value("Time", point.x), y: .value("Temperature", value), series: .value("Part", "Controller"))
                            .foregroundStyle(Palette.controllerTemperature)
                            .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                            .interpolationMethod(.monotone)
                    }
                    if let value = point.motor {
                        LineMark(x: .value("Time", point.x), y: .value("Temperature", value), series: .value("Part", "Motor"))
                            .foregroundStyle(Palette.motorTemperature)
                            .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round, dash: [5, 3]))
                            .interpolationMethod(.monotone)
                    }
                }
                ForEach(limitRules(controller: controller, motor: motor)) { limit in
                    rule(limit.name, limit.threshold, limit.severity.color)
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
                AxisMarks(values: xTicks) { value in
                    AxisTick()
                    AxisValueLabel {
                        if let x = value.as(X.self) { Text(xLabel(x)) }
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
            .frame(height: height)
            .clipped()
            .overlay {
                if points.count < 2 {
                    Text("Waiting for data").font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Temperature over time")
        .accessibilityValue(summary(controller: controller.last, motor: motor.last))
    }

    /// Temperature rules the readings are getting near, drawn in their colour.
    private func limitRules(controller: [Double], motor: [Double]) -> [AlertRule] {
        let center = AlertRuleCenter.shared
        let near: (AlertMetric, [Double]) -> [AlertRule] = { metric, values in
            guard let peak = values.max() else { return [] }
            return center.limits(for: metric).filter { peak >= $0.threshold - 15 }
        }
        return near(.controllerTemperature, controller) + near(.motorTemperature, motor)
    }

    private func rule(_ title: String, _ value: Double, _ tint: Color) -> some ChartContent {
        RuleMark(y: .value(title, value))
            .foregroundStyle(tint.opacity(0.55))
            .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 4]))
    }

    private func legend(_ title: String, _ tint: Color, value: Double?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Circle().fill(tint).frame(width: 8, height: 8)
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            Text(value.map { "\(Int($0.rounded()))°C" } ?? "–")
                .font(.system(.title3, design: .rounded, weight: .semibold))
                .monospacedDigit()
        }
    }

    private func nearestPoint() -> Point? {
        guard let selection else { return points.last }
        return points.min { distance($0.x, selection) < distance($1.x, selection) }
    }

    private func distance(_ a: X, _ b: X) -> Double {
        if let a = a as? Date, let b = b as? Date { return abs(a.timeIntervalSince(b)) }
        if let a = a as? Double, let b = b as? Double { return abs(a - b) }
        return 0
    }

    private func summary(controller: Double?, motor: Double?) -> String {
        let parts = [controller.map { "Controller \(Int($0.rounded())) degrees" }, motor.map { "motor \(Int($0.rounded())) degrees" }]
        return parts.compactMap { $0 }.joined(separator: ", ")
    }
}
