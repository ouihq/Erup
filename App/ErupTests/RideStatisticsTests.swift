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

import SwiftData

@MainActor
final class RideRecorderPersistenceTests: XCTestCase {
    private let origin = Date(timeIntervalSinceReferenceDate: 5_000_000)

    private func makeRecorder() throws -> (RideRecorder, ModelContainer) {
        let container = try ModelContainer(
            for: Ride.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let store = ScooterStore(link: MockScooter(behavior: .init(simulatesRide: false, startsPaired: false)))
        return (RideRecorder(store: store, container: container), container)
    }

    private func sample(_ seconds: TimeInterval, speed: Double) -> TelemetrySample {
        TelemetrySample(date: origin.addingTimeInterval(seconds), speedKmh: speed, voltage: 41, current: speed > 0 ? 5 : 0,
                        batteryPercent: 80, controllerTemperature: 30, motorTemperature: 35)
    }

    private func rides(_ container: ModelContainer) throws -> [Ride] {
        try container.mainContext.fetch(FetchDescriptor<Ride>(sortBy: [SortDescriptor(\.startedAt)]))
    }

    func testARideIsStoredWhileItIsStillInProgress() throws {
        let (recorder, container) = try makeRecorder()
        // 60 seconds of riding at 20 km/h and then nothing more: the app is killed here.
        for t in 0..<60 { recorder.ingest(sample(TimeInterval(t), speed: 20)) }

        let stored = try rides(container)
        XCTAssertEqual(stored.count, 1, "the ride must exist before it has ended")
        XCTAssertGreaterThan(stored[0].distanceKm, 0.1)
        XCTAssertGreaterThan(stored[0].duration, 30)
    }

    func testTheStoredRideKeepsGrowingAndEndsAsOneRide() throws {
        let (recorder, container) = try makeRecorder()
        for t in 0..<60 { recorder.ingest(sample(TimeInterval(t), speed: 20)) }
        let midway = try rides(container)[0].distanceKm
        for t in 60..<120 { recorder.ingest(sample(TimeInterval(t), speed: 20)) }
        // Standing still ends the ride after the stationary timeout.
        for t in 120..<260 { recorder.ingest(sample(TimeInterval(t), speed: 0)) }

        let stored = try rides(container)
        XCTAssertEqual(stored.count, 1)
        XCTAssertGreaterThan(stored[0].distanceKm, midway)
        XCTAssertEqual(stored[0].duration, 120, accuracy: 3, "the standing time at the end is not part of the ride")
    }

    func testARideThatRestartsShortlyAfterwardsContinuesTheStoredRide() throws {
        let (recorder, container) = try makeRecorder()
        for t in 0..<60 { recorder.ingest(sample(TimeInterval(t), speed: 20)) }
        for t in 60..<200 { recorder.ingest(sample(TimeInterval(t), speed: 0)) }
        let firstDistance = try rides(container)[0].distanceKm
        // The rider continues about a minute later.
        for t in 260..<330 { recorder.ingest(sample(TimeInterval(t), speed: 20)) }

        let stored = try rides(container)
        XCTAssertEqual(stored.count, 1, "a short stop must not split the ride")
        XCTAssertGreaterThan(stored[0].distanceKm, firstDistance)
    }

    func testRidesFarApartStayApart() throws {
        let (recorder, container) = try makeRecorder()
        for t in 0..<60 { recorder.ingest(sample(TimeInterval(t), speed: 20)) }
        for t in 60..<200 { recorder.ingest(sample(TimeInterval(t), speed: 0)) }
        for t in 1_000..<1_060 { recorder.ingest(sample(TimeInterval(t), speed: 20)) }

        XCTAssertEqual(try rides(container).count, 2)
    }

    func testPersistingOnBackgroundStoresTheRideSoFar() throws {
        let (recorder, container) = try makeRecorder()
        for t in 0..<8 { recorder.ingest(sample(TimeInterval(t), speed: 20)) }
        XCTAssertEqual(try rides(container).count, 0, "too short to keep yet")
        for t in 8..<25 { recorder.ingest(sample(TimeInterval(t), speed: 20)) }
        recorder.persistDraftNow()
        XCTAssertEqual(try rides(container).count, 1)
    }
}
