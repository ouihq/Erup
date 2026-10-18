import XCTest
@testable import ScooterAnalytics

final class RideDetectorTests: XCTestCase {
    private let origin = Date(timeIntervalSinceReferenceDate: 1_000_000)

    private func sample(
        _ seconds: TimeInterval, speed: Double = 0, voltage: Double = 41, current: Double = 0, battery: Int = 80
    ) -> TelemetrySample {
        TelemetrySample(
            date: origin.addingTimeInterval(seconds), speedKmh: speed, voltage: voltage, current: current,
            batteryPercent: battery, controllerTemperature: 30 + Int(seconds / 10), motorTemperature: 35
        )
    }

    private func run(_ detector: inout RideDetector, _ samples: [TelemetrySample]) -> [RideDetector.Event] {
        samples.flatMap { detector.ingest($0) }
    }

    private func standardRide() -> [TelemetrySample] {
        var samples: [TelemetrySample] = []
        for t in 0..<5 { samples.append(sample(TimeInterval(t))) }
        for t in 5..<65 { samples.append(sample(TimeInterval(t), speed: 20, current: 5, battery: t < 40 ? 80 : 79)) }
        for t in 65..<195 { samples.append(sample(TimeInterval(t), battery: 79)) }
        return samples
    }

    func testDetectsStartAndEndAfterStationaryTimeout() throws {
        var detector = RideDetector()
        let events = run(&detector, standardRide())

        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events.first, .started(origin.addingTimeInterval(5)))
        guard case .ended(let ride) = events.last else { return XCTFail("no ride end") }
        XCTAssertEqual(ride.duration, 60, accuracy: 1)
        XCTAssertEqual(ride.distanceKm, 0.33, accuracy: 0.01)
        XCTAssertEqual(ride.averageSpeedKmh, 19.8, accuracy: 0.6)
        XCTAssertEqual(ride.maxSpeedKmh, 20)
        XCTAssertEqual(ride.energyWh, 3.4, accuracy: 0.2)
        XCTAssertEqual(ride.batteryStart, 80)
        XCTAssertEqual(ride.batteryEnd, 79)
        XCTAssertFalse(detector.isRiding)
    }

    func testStoredSamplesAreDownsampledAndTrimmed() throws {
        var detector = RideDetector()
        let events = run(&detector, standardRide())
        guard case .ended(let ride) = events.last else { return XCTFail("no ride end") }
        XCTAssertLessThanOrEqual(ride.samples.last?.offset ?? 0, ride.duration)
        XCTAssertGreaterThan(ride.samples.count, 55)
        XCTAssertLessThan(ride.samples.count, 70)
    }

    func testBriefSpeedBlipDoesNotStartARide() {
        var detector = RideDetector()
        let events = run(&detector, [sample(0, speed: 20), sample(1, speed: 20), sample(2, speed: 0), sample(3, speed: 0)])
        XCTAssertTrue(events.isEmpty)
        XCTAssertFalse(detector.isRiding)
    }

    func testLongGapEndsTheRideAtTheLastSample() {
        var detector = RideDetector()
        var samples = (0..<30).map { sample(TimeInterval($0), speed: 20, current: 5) }
        samples.append(sample(200))
        let events = run(&detector, samples)
        guard case .ended(let ride) = events.last else { return XCTFail("expected a ride end, got \(events)") }
        XCTAssertEqual(ride.duration, 29, accuracy: 1)
    }

    func testTinyRideIsDiscarded() {
        var detector = RideDetector()
        var samples = (0..<10).map { sample(TimeInterval($0), speed: 20, current: 5) }
        samples += (10..<140).map { sample(TimeInterval($0)) }
        let events = run(&detector, samples)
        XCTAssertTrue(events.contains(.discarded))
        XCTAssertFalse(events.contains { if case .ended = $0 { true } else { false } })
    }

    func testFinishClosesARideInProgress() {
        var detector = RideDetector()
        _ = run(&detector, (0..<40).map { sample(TimeInterval($0), speed: 20, current: 5) })
        XCTAssertTrue(detector.isRiding)
        let events = detector.finish()
        guard case .ended = events.first else { return XCTFail("expected a ride end") }
        XCTAssertFalse(detector.isRiding)
    }

    func testRideSummaryCarriesSagEstimate() {
        var detector = RideDetector()
        var samples = [sample(0, voltage: 42, current: 0)]
        samples += (1..<60).map { sample(TimeInterval($0), speed: 20, voltage: 38, current: 20) }
        samples += (60..<200).map { sample(TimeInterval($0), voltage: 42, current: 0) }
        let events = run(&detector, samples)
        guard case .ended(let ride) = events.last else { return XCTFail("no ride end") }
        XCTAssertEqual(ride.internalResistanceOhm ?? 0, 0.2, accuracy: 0.001)
    }
}

final class SagEstimatorTests: XCTestCase {
    private func sample(_ seconds: TimeInterval, voltage: Double, current: Double, battery: Int = 80) -> TelemetrySample {
        TelemetrySample(date: Date(timeIntervalSinceReferenceDate: seconds), speedKmh: 10, voltage: voltage,
                        current: current, batteryPercent: battery, controllerTemperature: 30, motorTemperature: 30)
    }

    func testNeedsEnoughEstimatesBeforeReporting() {
        var estimator = SagEstimator()
        estimator.ingest(sample(0, voltage: 42, current: 0))
        for t in 1...4 { estimator.ingest(sample(TimeInterval(t), voltage: 38, current: 20)) }
        XCTAssertNil(estimator.medianOhms)
        estimator.ingest(sample(5, voltage: 38, current: 20))
        XCTAssertEqual(estimator.medianOhms ?? 0, 0.2, accuracy: 1e-9)
    }

    func testIgnoresStaleRestVoltageAndDifferentChargeLevel() {
        var estimator = SagEstimator()
        estimator.ingest(sample(0, voltage: 42, current: 0, battery: 90))
        for t in 1...6 { estimator.ingest(sample(TimeInterval(t), voltage: 38, current: 20, battery: 80)) }
        XCTAssertTrue(estimator.estimates.isEmpty)

        estimator.ingest(sample(10, voltage: 42, current: 0, battery: 80))
        for t in 300...306 { estimator.ingest(sample(TimeInterval(t), voltage: 38, current: 20, battery: 80)) }
        XCTAssertTrue(estimator.estimates.isEmpty)
    }

    func testIgnoresImplausibleValues() {
        var estimator = SagEstimator()
        estimator.ingest(sample(0, voltage: 42, current: 0))
        for t in 1...6 { estimator.ingest(sample(TimeInterval(t), voltage: 10, current: 6)) }
        XCTAssertTrue(estimator.estimates.isEmpty)
    }
}

final class RangeEstimatorTests: XCTestCase {
    private let ride = RideEnergyRecord(distanceKm: 10, energyWh: 300, batteryStart: 90, batteryEnd: 60)

    func testCalibratesCapacityAndConsumptionFromRides() throws {
        let model = try XCTUnwrap(RangeEstimator.model(rides: [ride, ride], manualCapacityWh: nil))
        XCTAssertEqual(model.whPerKm, 30, accuracy: 1e-9)
        XCTAssertEqual(model.capacityWh, 1000, accuracy: 1e-9)
        XCTAssertTrue(model.isCapacityCalibrated)
        XCTAssertEqual(model.rangeKm(batteryPercent: 50), 16.67, accuracy: 0.01)
        XCTAssertEqual(model.rangeKm(batteryPercent: 150), model.rangeKm(batteryPercent: 100))
    }

    func testManualCapacityNeedsOnlyConsumption() throws {
        let short = RideEnergyRecord(distanceKm: 4, energyWh: 100, batteryStart: 90, batteryEnd: 85)
        let model = try XCTUnwrap(RangeEstimator.model(rides: [short], manualCapacityWh: 500))
        XCTAssertEqual(model.whPerKm, 25, accuracy: 1e-9)
        XCTAssertEqual(model.rangeKm(batteryPercent: 100), 20, accuracy: 1e-9)
        XCTAssertFalse(model.isCapacityCalibrated)
    }

    func testReturnsNothingWithoutEnoughHistory() {
        XCTAssertNil(RangeEstimator.model(rides: [], manualCapacityWh: 500))
        let shortRide = RideEnergyRecord(distanceKm: 1, energyWh: 30, batteryStart: 90, batteryEnd: 88)
        XCTAssertNil(RangeEstimator.model(rides: [shortRide], manualCapacityWh: 500))
        XCTAssertNil(RangeEstimator.model(rides: [shortRide, shortRide, shortRide, shortRide], manualCapacityWh: nil))
    }

    func testOnlyTheMostRecentRidesCount() throws {
        let old = RideEnergyRecord(distanceKm: 10, energyWh: 600, batteryStart: 90, batteryEnd: 60)
        let rides = Array(repeating: ride, count: 10) + [old]
        let model = try XCTUnwrap(RangeEstimator.model(rides: rides, manualCapacityWh: 1000))
        XCTAssertEqual(model.whPerKm, 30, accuracy: 1e-9)
    }
}
