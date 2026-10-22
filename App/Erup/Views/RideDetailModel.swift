import CoreLocation
import Foundation
import MapKit
import ScooterAnalytics

/// The four things a ride detail charts.
enum RideMetric: String, CaseIterable, Sendable {
    case speed, power, voltage, battery

    var title: String {
        switch self {
        case .speed: "Speed"
        case .power: "Power"
        case .voltage: "Voltage"
        case .battery: "Battery"
        }
    }

    /// Digits shown after the decimal separator.
    var digits: Int { self == .speed || self == .voltage ? 1 : 0 }

    /// The value in the units the samples are stored in (km/h, W, V, %).
    func value(_ sample: RideSample) -> Double {
        switch self {
        case .speed: sample.speedKmh
        case .power: sample.powerWatts
        case .voltage: sample.voltage
        case .battery: Double(sample.batteryPercent)
        }
    }

    /// The vertical range of the chart, so a flat ride does not collapse into a line and power can go below zero.
    func domain(minimum low: Double, maximum high: Double) -> ClosedRange<Double> {
        switch self {
        case .speed: 0...max(high, 10) * 1.15
        case .power: min(low * 1.15, 0)...max(high, 100) * 1.15
        case .battery: min(max(0, low - 3), 90)...100
        case .voltage: (low - 0.5)...(high + 0.5)
        }
    }
}

struct SeriesPoint: Sendable {
    let offset: TimeInterval
    let value: Double
}

/// One metric of one ride, prepared once: thinned for drawing (keeping the peaks), with its statistics. It never changes,
/// so a chart can tell in one comparison that nothing needs redrawing while a finger moves over a different chart.
final class RideSeries: Sendable {
    let metric: RideMetric
    /// Every stored sample, for exact readings at the line.
    let samples: [RideSample]
    /// The points that are drawn.
    let drawn: [SeriesPoint]
    let average: Double
    let minimum: Double
    let maximum: Double
    let duration: TimeInterval

    private static let maximumPoints = 240

    init(metric: RideMetric, samples: [RideSample]) {
        self.metric = metric
        self.samples = samples
        let values = samples.map(metric.value)
        drawn = SeriesDecimation.indices(of: values, maximumPoints: Self.maximumPoints).map {
            SeriesPoint(offset: samples[$0].offset, value: values[$0])
        }
        average = values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
        minimum = values.min() ?? 0
        maximum = values.max() ?? 0
        duration = max(samples.last?.offset ?? 60, 60)
    }

    var domain: ClosedRange<Double> { metric.domain(minimum: minimum, maximum: maximum) }

    /// Enough points to draw a line.
    var isDrawable: Bool { drawn.count >= 2 }

    func sample(at offset: TimeInterval) -> RideSample? { RideInsights.sample(at: offset, in: samples) }
}

/// The recorded route, prepared once for the map: the time of every point (so a moment in the charts finds its place),
/// the stretches colored by speed, and the area the map should show.
final class RouteGeometry: Sendable {
    let coordinates: [CLLocationCoordinate2D]
    let dates: [Date]
    let segments: [RouteSegment]
    /// The fastest speed on the route, which the color scale runs up to.
    let maximumSpeedKmh: Double
    /// The whole route with some room around it.
    let fittedRect: MKMapRect

    init(points: [TrackPoint], startedAt: Date, samples: [RideSample]) {
        coordinates = points.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
        dates = points.map(\.timestamp)
        segments = RouteColoring.segments(dates: dates, startedAt: startedAt, samples: samples)
        maximumSpeedKmh = max(segments.map(\.speedKmh).max() ?? 0, 1)
        fittedRect = Self.fittedRect(for: coordinates)
    }

    /// The route point nearest to a place on the map.
    func nearestIndex(to coordinate: CLLocationCoordinate2D) -> Int? {
        RouteColoring.nearestPoint(
            toLatitude: coordinate.latitude, longitude: coordinate.longitude,
            in: coordinates.map { (latitude: $0.latitude, longitude: $0.longitude) }
        )
    }

    /// A very short route still gets a sensible view (at least a few hundred metres across), and every route gets a margin.
    static func fittedRect(for coordinates: [CLLocationCoordinate2D]) -> MKMapRect {
        guard let first = coordinates.first else { return .world }
        var rect = MKMapRect(origin: MKMapPoint(first), size: MKMapSize(width: 0, height: 0))
        for coordinate in coordinates.dropFirst() {
            rect = rect.union(MKMapRect(origin: MKMapPoint(coordinate), size: MKMapSize(width: 0, height: 0)))
        }
        let metre = MKMapPointsPerMeterAtLatitude(first.latitude)
        let minimum = 400 * metre
        let width = max(rect.width, minimum), height = max(rect.height, minimum)
        let centre = MKMapPoint(x: rect.midX, y: rect.midY)
        let marginFactor = 1.35
        return MKMapRect(x: centre.x - width * marginFactor / 2, y: centre.y - height * marginFactor / 2,
                         width: width * marginFactor, height: height * marginFactor)
    }
}

/// Everything the ride detail needs, decoded and computed once off the main thread.
struct RideDetailData: Sendable {
    let samples: [RideSample]
    let digest: RideDigest
    let series: [RideSeries]
    let regen: [RegenSegment]
    /// Estimated from the stored samples. Rides recorded since the exact amount is measured carry it themselves.
    let estimatedRegenWh: Double
    let highlights: RideInsights.Highlights
    let route: RouteGeometry?
    /// The route point where the top speed was reached, marked on the map.
    let topSpeedRouteIndex: Int?
    let samplesError: String?
    let trackError: String?

    /// Decodes the stored data. Runs off the main thread: a long ride has thousands of samples to decompress.
    static func make(samplesData: Data, trackData: Data?, startedAt: Date = .distantPast) -> RideDetailData {
        var samples: [RideSample] = []
        var samplesError: String?
        do {
            samples = try PackedData.decode([RideSample].self, from: samplesData)
        } catch {
            samplesError = error.localizedDescription
        }
        var route: RouteGeometry?
        var trackError: String?
        if let trackData {
            do {
                let points = try PackedData.decode([TrackPoint].self, from: trackData)
                if points.count > 1 { route = RouteGeometry(points: points, startedAt: startedAt, samples: samples) }
            } catch {
                trackError = error.localizedDescription
            }
        }
        let highlights = RideInsights.highlights(in: samples)
        let topSpeedIndex = route.flatMap { route in
            highlights.topSpeed.flatMap { RideInsights.nearestIndex(to: startedAt.addingTimeInterval($0.offset), in: route.dates) }
        }
        return RideDetailData(
            samples: samples,
            digest: RideDigest(samples: samples),
            series: samples.isEmpty ? [] : RideMetric.allCases.map { RideSeries(metric: $0, samples: samples) },
            regen: RideInsights.regenSegments(in: samples),
            estimatedRegenWh: RideInsights.estimatedRegenWh(in: samples),
            highlights: highlights,
            route: route, topSpeedRouteIndex: topSpeedIndex, samplesError: samplesError, trackError: trackError
        )
    }
}
