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
                Section(dayTitle(day.day)) {
                    ForEach(day.rides) { ride in
                        NavigationLink {
                            RideDetailView(ride: ride)
                        } label: {
                            RideRow(ride: ride, units: units)
                        }
                    }
                    .onDelete { offsets in delete(offsets.map { day.rides[$0] }) }
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
                    Label("\(units.speed(fromKmh: ride.averageSpeedKmh).formatted(.number.precision(.fractionLength(0)))) \(units.speedLabel)", systemImage: "speedometer")
                    if let whPerKm = ride.whPerKm {
                        Label("\(units.perDistance(whPerKm).formatted(.number.precision(.fractionLength(0)))) Wh/\(units.distanceLabel)", systemImage: "leaf")
                    }
                    Label("\(ride.batteryUsed)%", systemImage: "battery.50percent")
                }
                .labelStyle(CompactLabelStyle())
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
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon.imageScale(.small)
            configuration.title
        }
    }
}

struct RideDetailView: View {
    let ride: Ride
    @AppStorage("useMiles") private var useMiles = false
    @State private var decoded: Decoded?

    private struct Decoded {
        let samples: Result<[RideSample], Error>
        let track: Result<[TrackPoint], Error>
    }

    private var units: Units { Units(useMiles: useMiles) }

    var body: some View {
        let samples = decoded?.samples ?? .success([])
        let track = decoded?.track ?? .success([])
        ScrollView {
            VStack(spacing: 16) {
                if case .success(let points) = track, points.count > 1 {
                    RouteMap(points: points)
                        .frame(height: 260)
                        .clipShape(RoundedRectangle(cornerRadius: 20))
                } else if decoded != nil, case .success = track {
                    noRouteCard
                }
                hero
                details
                switch samples {
                case .success(let values) where !values.isEmpty:
                    RideCharts(samples: values, units: units)
                case .success:
                    EmptyView()
                case .failure(let error):
                    Label("Charts unavailable: \(error.localizedDescription)", systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if case .failure(let error) = track {
                    Label("Route unavailable: \(error.localizedDescription)", systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .background(Color(.systemGroupedBackground))
        .task(id: ride.id) {
            decoded = Decoded(samples: Result { try ride.decodedSamples() }, track: Result { try ride.decodedTrack() })
        }
        .navigationTitle(ride.startedAt.formatted(date: .abbreviated, time: .shortened))
        .navigationBarTitleDisplayMode(.inline)
    }

    @ScaledMetric(relativeTo: .largeTitle) private var heroSize: CGFloat = 48

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

    private var details: some View {
        VStack(spacing: 0) {
            detailRow("Energy used", "\(ride.energyWh.formatted(.number.precision(.fractionLength(1)))) Wh", symbol: "bolt.fill", tint: Palette.power)
            Divider()
            detailRow(
                "Consumption",
                ride.whPerKm.map { "\(units.perDistance($0).formatted(.number.precision(.fractionLength(0)))) Wh/\(units.distanceLabel)" } ?? "–",
                symbol: "leaf.fill", tint: Palette.battery
            )
            Divider()
            detailRow("Battery", "\(ride.batteryStart)% → \(ride.batteryEnd)%", symbol: "battery.50percent", tint: Palette.battery)
            Divider()
            detailRow("Controller peak", "\(ride.maxControllerTemperature)°C", symbol: "thermometer.medium", tint: Palette.temperature)
            Divider()
            detailRow("Motor peak", "\(ride.maxMotorTemperature)°C", symbol: "thermometer.high", tint: Palette.temperature)
        }
        .padding(.horizontal, 14)
        .cardBackground(cornerRadius: 16)
    }

    private func detailRow(_ title: String, _ value: String, symbol: String, tint: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).foregroundStyle(tint).frame(width: 24)
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value).fontWeight(.medium).monospacedDigit().multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
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

struct RouteMap: View {
    let points: [TrackPoint]

    var body: some View {
        let coordinates = points.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
        Map(initialPosition: .automatic, interactionModes: [.zoom, .pan]) {
            MapPolyline(coordinates: coordinates)
                .stroke(.tint, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
            if let first = coordinates.first {
                Annotation("Start", coordinate: first) {
                    Circle().fill(.green).frame(width: 14, height: 14).overlay(Circle().stroke(.white, lineWidth: 3))
                }
            }
            if let last = coordinates.last {
                Annotation("End", coordinate: last) {
                    Circle().fill(.red).frame(width: 14, height: 14).overlay(Circle().stroke(.white, lineWidth: 3))
                }
            }
        }
        .mapStyle(.standard(elevation: .realistic))
        .accessibilityLabel("Route map")
    }
}

struct RideCharts: View {
    let samples: [RideSample]
    let units: Units

    var body: some View {
        VStack(spacing: 16) {
            RideSeriesChart(
                title: "Speed", unit: units.speedLabel, tint: Palette.speed, samples: samples,
                value: { units.speed(fromKmh: $0.speedKmh) }, floor: .zero
            )
            RideSeriesChart(
                title: "Power", unit: "W", tint: Palette.power, samples: samples,
                value: { $0.powerWatts }, floor: .zeroOrBelow
            )
            RideSeriesChart(
                title: "Voltage", unit: "V", tint: Palette.voltage, samples: samples,
                value: { $0.voltage }, floor: .fittedVoltage
            )
            RideSeriesChart(
                title: "Battery", unit: "%", tint: Palette.battery, samples: samples,
                value: { Double($0.batteryPercent) }, floor: .fitted
            )
        }
    }
}

/// One ride metric drawn like the live dashboard chart: tinted line over a soft gradient, current reading and average/max in the header.
struct RideSeriesChart: View {
    enum Floor {
        case zero
        case zeroOrBelow
        case fitted
        case fittedVoltage
    }

    let title: String
    let unit: String
    let tint: Color
    let samples: [RideSample]
    let value: (RideSample) -> Double
    let floor: Floor

    private static let maxPoints = 200

    var body: some View {
        let points = downsampled()
        let values = points.map(\.1)
        let domain = yDomain(values)
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.subheadline.weight(.semibold))
                Spacer()
                if let maximum = values.max(), !values.isEmpty {
                    Text("Avg \(format(values.reduce(0, +) / Double(values.count))) · Max \(format(maximum)) \(unit)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            Chart {
                ForEach(points, id: \.0.offset) { sample, value in
                    AreaMark(
                        x: .value("Time", sample.offset),
                        yStart: .value("Base", domain.lowerBound),
                        yEnd: .value(title, value)
                    )
                    .foregroundStyle(LinearGradient(colors: [tint.opacity(0.35), tint.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.monotone)
                    LineMark(x: .value("Time", sample.offset), y: .value(title, value))
                        .foregroundStyle(tint)
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                        .interpolationMethod(.monotone)
                }
            }
            .chartXScale(domain: 0...max(samples.last?.offset ?? 60, 60))
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
            .clipped()
        }
        .padding(14)
        .cardBackground(cornerRadius: 16)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title) over the ride")
    }

    private func downsampled() -> [(RideSample, Double)] {
        let step = max(1, samples.count / Self.maxPoints)
        return samples.enumerated()
            .filter { $0.offset % step == 0 || $0.offset == samples.count - 1 }
            .map { ($0.element, value($0.element)) }
    }

    private func yDomain(_ values: [Double]) -> ClosedRange<Double> {
        let high = values.max() ?? 0
        let low = values.min() ?? 0
        switch floor {
        case .zero: return 0...max(high, 10) * 1.15
        case .zeroOrBelow: return min(low, 0)...max(high, 100) * 1.15
        case .fitted:
            let bottom = max(0, low - 3)
            return min(bottom, 90)...100
        case .fittedVoltage:
            return (low - 0.5)...(high + 0.5)
        }
    }

    private func timeLabel(_ seconds: Double) -> String {
        seconds < 60 ? "\(Int(seconds))s" : "\(Int((seconds / 60).rounded()))m"
    }

    private func format(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0)))
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
