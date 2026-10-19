import Foundation

/// A stretch of a recorded route with the speed the rider had there, for coloring the route on a map.
public struct RouteSegment: Equatable, Sendable {
    /// Index of the first and last route point of the stretch. Neighbouring stretches share a point, so the route has no gaps.
    public let first: Int
    public let last: Int
    public let speedKmh: Double
}

public enum RouteColoring {
    /// Splits a route into at most `maximumSegments` stretches and gives each the speed at its middle, read from the
    /// ride's samples by time. Long rides have thousands of route points; a map copes much better with a few
    /// hundred colored stretches than with a line per point.
    public static func segments(dates: [Date], startedAt: Date, samples: [RideSample], maximumSegments: Int = 150) -> [RouteSegment] {
        guard dates.count >= 2, maximumSegments > 0 else { return [] }
        let step = max(1, Int((Double(dates.count - 1) / Double(maximumSegments)).rounded(.up)))
        var segments: [RouteSegment] = []
        var first = 0
        while first < dates.count - 1 {
            let last = min(first + step, dates.count - 1)
            let middle = dates[(first + last) / 2].timeIntervalSince(startedAt)
            segments.append(RouteSegment(first: first, last: last, speedKmh: RideInsights.sample(at: middle, in: samples)?.speedKmh ?? 0))
            first = last
        }
        return segments
    }

    /// Index of the route point closest to a position on the map. Distances use a flat approximation, which is exact
    /// enough over the size of a ride and cheap to compute for every point.
    public static func nearestPoint(toLatitude latitude: Double, longitude: Double, in points: [(latitude: Double, longitude: Double)]) -> Int? {
        guard !points.isEmpty else { return nil }
        let scale = cos(latitude * .pi / 180)
        var best = 0
        var bestDistance = Double.infinity
        for (index, point) in points.enumerated() {
            let dy = point.latitude - latitude
            let dx = (point.longitude - longitude) * scale
            let distance = dx * dx + dy * dy
            if distance < bestDistance {
                bestDistance = distance
                best = index
            }
        }
        return best
    }
}
