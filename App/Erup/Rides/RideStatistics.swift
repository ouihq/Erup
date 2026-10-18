import Foundation

/// The few numbers of a ride that the statistics need.
struct RideStatRecord: Equatable {
    let date: Date
    let km: Double
    let seconds: TimeInterval
    let maxKmh: Double
    let wh: Double
}

enum StatsScope: String, CaseIterable, Identifiable {
    case week = "Week"
    case month = "Month"
    case year = "Year"
    case all = "All"

    var id: String { rawValue }
}

struct StatsBucket: Identifiable, Equatable {
    var id: Date { start }
    let start: Date
    var km = 0.0
    var rides = 0
    var maxKmh = 0.0
}

struct RideStatistics: Equatable {
    var totalKm = 0.0
    var rides = 0
    var seconds = 0.0
    var topKmh = 0.0
    var wh = 0.0
    var buckets: [StatsBucket] = []
    /// What one bar covers.
    var bucketComponent: Calendar.Component = .day

    var averageKmh: Double { seconds > 0 ? totalKm / (seconds / 3600) : 0 }
    var whPerKm: Double? { totalKm >= 0.1 && wh > 0 ? wh / totalKm : nil }

    /// Totals for the chosen scope and one bucket per day or month in it, with empty periods included.
    static func compute(
        _ records: [RideStatRecord], scope: StatsScope, now: Date = .now, calendar: Calendar = .current
    ) -> RideStatistics {
        let today = calendar.startOfDay(for: now)
        let component: Calendar.Component
        let first: Date
        let count: Int
        switch scope {
        case .week:
            component = .day
            first = calendar.date(byAdding: .day, value: -6, to: today) ?? today
            count = 7
        case .month:
            component = .day
            first = calendar.date(byAdding: .day, value: -29, to: today) ?? today
            count = 30
        case .year, .all:
            component = .month
            let thisMonth = calendar.dateInterval(of: .month, for: today)?.start ?? today
            var months = 12
            if scope == .all, let earliest = records.map(\.date).min() {
                let earliestMonth = calendar.dateInterval(of: .month, for: earliest)?.start ?? earliest
                let span = calendar.dateComponents([.month], from: earliestMonth, to: thisMonth).month ?? 0
                months = max(6, span + 1)
            }
            first = calendar.date(byAdding: .month, value: -(months - 1), to: thisMonth) ?? thisMonth
            count = months
        }

        var stats = RideStatistics(bucketComponent: component)
        stats.buckets = (0..<count).compactMap { offset in
            calendar.date(byAdding: component, value: offset, to: first).map { StatsBucket(start: $0) }
        }
        let scoped = scope == .all ? records : records.filter { $0.date >= first }
        for record in scoped {
            stats.totalKm += record.km
            stats.rides += 1
            stats.seconds += record.seconds
            stats.wh += record.wh
            stats.topKmh = max(stats.topKmh, record.maxKmh)
            guard let index = stats.buckets.lastIndex(where: { $0.start <= record.date }) else { continue }
            stats.buckets[index].km += record.km
            stats.buckets[index].rides += 1
            stats.buckets[index].maxKmh = max(stats.buckets[index].maxKmh, record.maxKmh)
        }
        return stats
    }
}
