import XCTest
@testable import Erup

final class RideStatisticsTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    private func record(_ when: Date, km: Double, seconds: Double = 600, maxKmh: Double, wh: Double = 50) -> RideStatRecord {
        RideStatRecord(date: when, km: km, seconds: seconds, maxKmh: maxKmh, wh: wh)
    }

    func testWeekCountsOnlyTheLastSevenDaysAndFillsEmptyDays() {
        let now = date(2026, 10, 18)
        let records = [
            record(date(2026, 10, 18, hour: 8), km: 4, maxKmh: 22),
            record(date(2026, 10, 18, hour: 18), km: 2, maxKmh: 31),
            record(date(2026, 10, 14), km: 5, maxKmh: 24),
            record(date(2026, 10, 1), km: 99, maxKmh: 40),
        ]
        let stats = RideStatistics.compute(records, scope: .week, now: now, calendar: calendar)
        XCTAssertEqual(stats.buckets.count, 7)
        XCTAssertEqual(stats.totalKm, 11, accuracy: 0.001)
        XCTAssertEqual(stats.rides, 3)
        XCTAssertEqual(stats.topKmh, 31)
        XCTAssertEqual(stats.buckets.last?.km ?? 0, 6, accuracy: 0.001, "both rides of today share one bar")
        XCTAssertEqual(stats.buckets.filter { $0.rides == 0 }.count, 5)
    }

    func testAllTimeIncludesEveryRideAndGroupsByMonth() {
        let now = date(2026, 10, 18)
        let records = [
            record(date(2026, 10, 2), km: 3, maxKmh: 20),
            record(date(2026, 3, 9), km: 7, maxKmh: 33),
            record(date(2025, 12, 24), km: 10, maxKmh: 26),
        ]
        let stats = RideStatistics.compute(records, scope: .all, now: now, calendar: calendar)
        XCTAssertEqual(stats.bucketComponent, .month)
        XCTAssertEqual(stats.totalKm, 20, accuracy: 0.001)
        XCTAssertEqual(stats.topKmh, 33)
        XCTAssertEqual(stats.buckets.count, 11)
        XCTAssertEqual(stats.buckets.first?.km ?? 0, 10, accuracy: 0.001)
        XCTAssertEqual(stats.buckets.last?.km ?? 0, 3, accuracy: 0.001)
    }

    func testAverageSpeedAndEnergyUseTotals() {
        let now = date(2026, 10, 18)
        let records = [
            record(date(2026, 10, 17), km: 6, seconds: 1200, maxKmh: 25, wh: 90),
            record(date(2026, 10, 18), km: 4, seconds: 1200, maxKmh: 22, wh: 60),
        ]
        let stats = RideStatistics.compute(records, scope: .month, now: now, calendar: calendar)
        XCTAssertEqual(stats.averageKmh, 15, accuracy: 0.001)
        XCTAssertEqual(stats.whPerKm ?? 0, 15, accuracy: 0.001)
    }

    func testNoRidesGivesEmptyStatistics() {
        let stats = RideStatistics.compute([], scope: .year, now: date(2026, 10, 18), calendar: calendar)
        XCTAssertEqual(stats.rides, 0)
        XCTAssertEqual(stats.buckets.count, 12)
        XCTAssertNil(stats.whPerKm)
        XCTAssertEqual(stats.averageKmh, 0)
    }

    func testStatisticsStayFastWithYearsOfRides() {
        let now = date(2026, 10, 18)
        let records = (0..<6000).map { index in
            record(now.addingTimeInterval(-Double(index) * 5_000), km: 3 + Double(index % 7), maxKmh: 20 + Double(index % 12))
        }
        let start = Date()
        for scope in StatsScope.allCases {
            let stats = RideStatistics.compute(records, scope: scope, now: now, calendar: calendar)
            XCTAssertGreaterThan(stats.rides, 0)
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.0, "four period views over 6000 rides must stay well under a second")
    }
}
