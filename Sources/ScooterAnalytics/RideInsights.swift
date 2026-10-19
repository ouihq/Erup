import Foundation

/// A stretch of a ride where the motor fed energy back into the battery (regenerative braking).
public struct RegenSegment: Equatable, Sendable {
    public let start: TimeInterval
    public let end: TimeInterval
}

/// Facts that can be read from the stored samples of one ride.
public enum RideInsights {
    /// Samples further apart than this are a gap in the data, so nothing is integrated across it.
    public static let maximumGap: TimeInterval = 5

    /// Every stretch with energy coming back, oldest first, for marking on the charts.
    public static func regenSegments(in samples: [RideSample]) -> [RegenSegment] {
        var segments: [RegenSegment] = []
        var first: RideSample?
        var last: RideSample?

        func close() {
            if let first, let last {
                segments.append(RegenSegment(start: first.offset, end: max(last.offset, first.offset + 1)))
            }
            first = nil
            last = nil
        }

        for sample in samples {
            if RegenDetection.isRegen(powerWatts: sample.powerWatts, speedKmh: sample.speedKmh) {
                if let last, sample.offset - last.offset > maximumGap { close() }
                if first == nil { first = sample }
                last = sample
            } else {
                close()
            }
        }
        close()
        return segments
    }

    /// An estimate of the energy recovered, from the stored samples (one per second). The recorder measures the exact
    /// amount from every reading while riding; this is for rides recorded before that, and uses the same maths.
    public static func estimatedRegenWh(in samples: [RideSample]) -> Double {
        var total = 0.0
        for (a, b) in zip(samples, samples.dropFirst()) {
            let dt = b.offset - a.offset
            guard dt > 0, dt <= maximumGap else { continue }
            let before = RegenDetection.recoveredWatts(powerWatts: a.powerWatts, speedKmh: a.speedKmh)
            let after = RegenDetection.recoveredWatts(powerWatts: b.powerWatts, speedKmh: b.speedKmh)
            total += (before + after) / 2 * dt / 3600
        }
        return total
    }

    /// The sample closest to a moment in the ride.
    public static func sample(at offset: TimeInterval, in samples: [RideSample]) -> RideSample? {
        guard var low = samples.indices.first else { return nil }
        var high = samples.indices.last!
        while low < high {
            let middle = (low + high) / 2
            if samples[middle].offset < offset { low = middle + 1 } else { high = middle }
        }
        guard low > 0 else { return samples[low] }
        let before = samples[low - 1], after = samples[low]
        return offset - before.offset <= after.offset - offset ? before : after
    }

    /// Index of the date closest to `target`, for putting a marker on a recorded route.
    public static func nearestIndex(to target: Date, in dates: [Date]) -> Int? {
        guard !dates.isEmpty else { return nil }
        var low = 0, high = dates.count - 1
        while low < high {
            let middle = (low + high) / 2
            if dates[middle] < target { low = middle + 1 } else { high = middle }
        }
        guard low > 0 else { return low }
        return target.timeIntervalSince(dates[low - 1]) <= dates[low].timeIntervalSince(target) ? low - 1 : low
    }

    /// The moments worth jumping to in a ride.
    public struct Highlights: Equatable, Sendable {
        public let topSpeed: RideSample?
        public let peakPower: RideSample?
    }

    public static func highlights(in samples: [RideSample]) -> Highlights {
        Highlights(
            topSpeed: samples.max { $0.speedKmh < $1.speedKmh },
            peakPower: samples.max { $0.powerWatts < $1.powerWatts }
        )
    }
}

/// Thinning a long series of points for drawing, without losing the peaks.
public enum SeriesDecimation {
    /// Indices of the points to draw, in order. Every bucket keeps its lowest and highest value, so a short peak (a top
    /// speed, a hard braking) is never skipped the way plain "every n-th point" sampling would skip it.
    public static func indices(of values: [Double], maximumPoints: Int) -> [Int] {
        guard values.count > maximumPoints, maximumPoints >= 4 else { return Array(values.indices) }
        let buckets = (maximumPoints - 2) / 2
        let size = Double(values.count - 2) / Double(buckets)
        var chosen: Set<Int> = [0, values.count - 1]
        for bucket in 0..<buckets {
            let start = 1 + Int(Double(bucket) * size)
            let end = min(values.count - 1, 1 + Int(Double(bucket + 1) * size))
            guard start < end else { continue }
            var low = start, high = start
            for index in start..<end {
                if values[index] < values[low] { low = index }
                if values[index] > values[high] { high = index }
            }
            chosen.insert(low)
            chosen.insert(high)
        }
        return chosen.sorted()
    }
}
