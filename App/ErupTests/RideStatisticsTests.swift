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

import ScooterAnalytics

final class RideMergeStorageTests: XCTestCase {
    private func summary(start: TimeInterval, duration: TimeInterval, distance: Double) -> RideSummary {
        let origin = Date(timeIntervalSinceReferenceDate: 4_000_000)
        return RideSummary(
            startedAt: origin.addingTimeInterval(start), endedAt: origin.addingTimeInterval(start + duration),
            distanceKm: distance, averageSpeedKmh: distance / (duration / 3600), maxSpeedKmh: 20, energyWh: 10,
            batteryStart: 80, batteryEnd: 78, maxControllerTemperature: 40, maxMotorTemperature: 45,
            internalResistanceOhm: nil,
            samples: [RideSample(offset: 0, speedKmh: 10, powerWatts: 50, batteryPercent: 80, voltage: 41),
                      RideSample(offset: duration, speedKmh: 0, powerWatts: 0, batteryPercent: 78, voltage: 40)]
        )
    }

    func testAStoredRideAbsorbsTheOneThatFollowedIt() throws {
        let first = summary(start: 0, duration: 600, distance: 3)
        let second = summary(start: 700, duration: 300, distance: 1)
        let origin = first.startedAt
        let firstTrack = [TrackPoint(latitude: 1, longitude: 1, timestamp: origin)]
        let secondTrack = [TrackPoint(latitude: 2, longitude: 2, timestamp: origin.addingTimeInterval(700))]

        let ride = try Ride.make(from: first, track: firstTrack)
        try ride.absorb(second, track: secondTrack)

        XCTAssertEqual(ride.startedAt, first.startedAt)
        XCTAssertEqual(ride.endedAt, second.endedAt)
        XCTAssertEqual(ride.distanceKm, 4, accuracy: 0.0001)
        XCTAssertEqual(ride.batteryEnd, 78)
        XCTAssertEqual(try ride.decodedSamples().map(\.offset), [0, 600, 700, 1000])
        XCTAssertEqual(try ride.decodedTrack().count, 2)
    }
}
