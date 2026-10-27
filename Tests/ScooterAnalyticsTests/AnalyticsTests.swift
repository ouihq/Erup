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

    func testGapBeyondFiveMinutesEndsTheRideAtTheLastSample() {
        var detector = RideDetector()
        var samples = (0..<30).map { sample(TimeInterval($0), speed: 20, current: 5) }
        samples.append(sample(400))
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

    func testRangeBandUsesTheMiddleHalfOfRecentRides() throws {
        let rides = [20.0, 25, 30, 35, 100].map { RideEnergyRecord(distanceKm: 4, energyWh: $0 * 4, batteryStart: 90, batteryEnd: 60) }
        let model = try XCTUnwrap(RangeEstimator.model(rides: rides, manualCapacityWh: 1000))
        let typical = try XCTUnwrap(model.typicalWhPerKm)
        XCTAssertEqual(typical.lowerBound, 25, accuracy: 1e-9)
        XCTAssertEqual(typical.upperBound, 35, accuracy: 1e-9, "the 100 Wh/km outlier does not widen the band")
        let band = try XCTUnwrap(model.rangeBandKm(batteryPercent: 100))
        XCTAssertEqual(band.lowerBound, 1000 / 35, accuracy: 1e-9)
        XCTAssertEqual(band.upperBound, 1000 / 25, accuracy: 1e-9)
    }

    func testRatedCapacityIsUsedUntilRidesShowMore() throws {
        let gentle = RideEnergyRecord(distanceKm: 4, energyWh: 80, batteryStart: 90, batteryEnd: 85)
        let model = try XCTUnwrap(RangeEstimator.model(rides: [gentle], manualCapacityWh: nil, nominalCapacityWh: 342))
        XCTAssertEqual(model.capacityWh, 342)
        XCTAssertFalse(model.isCapacityCalibrated)
        XCTAssertNil(RangeEstimator.model(rides: [gentle], manualCapacityWh: nil), "without a rating there is still nothing to show")
    }

    func testLearnedCapacityStaysNearTheRating() throws {
        let noisy = RideEnergyRecord(distanceKm: 10, energyWh: 300, batteryStart: 90, batteryEnd: 60)
        let model = try XCTUnwrap(RangeEstimator.model(rides: [noisy, noisy], manualCapacityWh: nil, nominalCapacityWh: 342))
        XCTAssertEqual(model.capacityWh, 342 * 1.2, accuracy: 1e-9, "1000 Wh from coarse readings is capped")
        XCTAssertTrue(model.isCapacityCalibrated)
    }

    func testNoBandWithFewRides() throws {
        let model = try XCTUnwrap(RangeEstimator.model(rides: [ride, ride], manualCapacityWh: 1000))
        XCTAssertNil(model.rangeBandKm(batteryPercent: 80))
    }
}

final class RideMergeTests: XCTestCase {
    private let origin = Date(timeIntervalSinceReferenceDate: 2_000_000)

    private func ride(start: TimeInterval, duration: TimeInterval, distance: Double, maxSpeed: Double = 20,
                      energy: Double = 5, battery: (Int, Int) = (80, 78), resistance: Double? = nil) -> RideSummary {
        RideSummary(
            startedAt: origin.addingTimeInterval(start), endedAt: origin.addingTimeInterval(start + duration),
            distanceKm: distance, averageSpeedKmh: distance / (duration / 3600), maxSpeedKmh: maxSpeed,
            energyWh: energy, batteryStart: battery.0, batteryEnd: battery.1,
            maxControllerTemperature: 40, maxMotorTemperature: 45, internalResistanceOhm: resistance,
            samples: [
                RideSample(offset: 0, speedKmh: 10, powerWatts: 100, batteryPercent: battery.0, voltage: 41),
                RideSample(offset: duration, speedKmh: 0, powerWatts: 0, batteryPercent: battery.1, voltage: 40),
            ]
        )
    }

    func testRidesCloseTogetherAreMergedButNotFarApartOrOverlapping() {
        let first = ride(start: 0, duration: 600, distance: 3)
        XCTAssertTrue(ride(start: 600 + 60, duration: 300, distance: 1).shouldMerge(after: first))
        XCTAssertTrue(ride(start: 600 + RideSummary.mergeGap, duration: 300, distance: 1).shouldMerge(after: first))
        XCTAssertFalse(ride(start: 600 + RideSummary.mergeGap + 1, duration: 300, distance: 1).shouldMerge(after: first))
        XCTAssertFalse(ride(start: 500, duration: 300, distance: 1).shouldMerge(after: first), "an overlapping ride is not a follow-up")
    }

    func testMergedRideAddsUpAndSpansBoth() {
        let first = ride(start: 0, duration: 600, distance: 3, maxSpeed: 22, energy: 40, battery: (80, 77), resistance: 0.2)
        let second = ride(start: 720, duration: 300, distance: 1.5, maxSpeed: 25, energy: 20, battery: (77, 75), resistance: 0.4)
        let merged = second.merged(after: first)

        XCTAssertEqual(merged.startedAt, first.startedAt)
        XCTAssertEqual(merged.endedAt, second.endedAt)
        XCTAssertEqual(merged.distanceKm, 4.5, accuracy: 0.0001)
        XCTAssertEqual(merged.energyWh, 60, accuracy: 0.0001)
        XCTAssertEqual(merged.maxSpeedKmh, 25)
        XCTAssertEqual(merged.batteryStart, 80)
        XCTAssertEqual(merged.batteryEnd, 75)
        XCTAssertEqual(merged.internalResistanceOhm ?? 0, 0.3, accuracy: 0.0001)
        // 4.5 km over 900 s of riding, not over the 1020 s including the pause.
        XCTAssertEqual(merged.averageSpeedKmh, 18, accuracy: 0.0001)
    }

    func testMergingKeepsTemperaturesAndPhoneSensorsAndContinuesTheHeight() {
        func sampled(altitude: Double) -> RideSummary {
            let base = ride(start: 0, duration: 100, distance: 1)
            return RideSummary(
                startedAt: base.startedAt, endedAt: base.endedAt, distanceKm: 1, averageSpeedKmh: 20, maxSpeedKmh: 20,
                energyWh: 5, batteryStart: 80, batteryEnd: 79, maxControllerTemperature: 40, maxMotorTemperature: 45,
                internalResistanceOhm: nil,
                samples: [
                    RideSample(offset: 0, speedKmh: 10, powerWatts: 100, batteryPercent: 80, voltage: 41, controllerTemperature: 33, motorTemperature: 29,
                               sensors: PhoneSensors(altitudeMeters: 0, vibrationG: 0.04)),
                    RideSample(offset: 100, speedKmh: 0, powerWatts: 0, batteryPercent: 79, voltage: 40, controllerTemperature: 34, motorTemperature: 30,
                               sensors: PhoneSensors(altitudeMeters: altitude, vibrationG: 0.05)),
                ]
            )
        }
        let first = sampled(altitude: 4)
        let originSecond = sampled(altitude: 2)
        let second = RideSummary(
            startedAt: first.endedAt.addingTimeInterval(60), endedAt: first.endedAt.addingTimeInterval(160), distanceKm: 1, averageSpeedKmh: 20,
            maxSpeedKmh: 20, energyWh: 5, batteryStart: 79, batteryEnd: 78, maxControllerTemperature: 40, maxMotorTemperature: 45,
            internalResistanceOhm: nil, samples: originSecond.samples
        )
        let merged = second.merged(after: first).samples
        XCTAssertEqual(merged.count, 4)
        XCTAssertEqual(merged[2].controllerTemperature, 33)
        XCTAssertEqual(merged[3].motorTemperature, 30)
        XCTAssertEqual(merged[2].sensors?.vibrationG, 0.04)
        // The second part started where the first ended (4 m up), so its own 0 and 2 m become 4 and 6.
        XCTAssertEqual(merged[2].sensors?.altitudeMeters, 4)
        XCTAssertEqual(merged[3].sensors?.altitudeMeters, 6)
    }

    func testSecondRidesSamplesAreShiftedOntoTheCombinedTimeline() {
        let first = ride(start: 0, duration: 600, distance: 3)
        let second = ride(start: 720, duration: 300, distance: 1)
        let offsets = second.merged(after: first).samples.map(\.offset)
        XCTAssertEqual(offsets, [0, 600, 720, 1020])
    }

    func testMergingKeepsAMissingResistanceFromEitherSide() {
        let first = ride(start: 0, duration: 600, distance: 3, resistance: nil)
        let second = ride(start: 700, duration: 300, distance: 1, resistance: 0.25)
        XCTAssertEqual(second.merged(after: first).internalResistanceOhm, 0.25)
        XCTAssertNil(ride(start: 700, duration: 300, distance: 1).merged(after: first).internalResistanceOhm)
    }
}

final class RideGapTests: XCTestCase {
    private let origin = Date(timeIntervalSinceReferenceDate: 3_000_000)

    private func riding(_ seconds: TimeInterval) -> TelemetrySample {
        TelemetrySample(date: origin.addingTimeInterval(seconds), speedKmh: 20, voltage: 41, current: 5,
                        batteryPercent: 80, controllerTemperature: 30, motorTemperature: 35)
    }

    private func ride(gap: TimeInterval) -> [RideDetector.Event] {
        var detector = RideDetector()
        var events: [RideDetector.Event] = []
        for t in 0..<40 { events += detector.ingest(riding(TimeInterval(t))) }
        for t in 0..<40 { events += detector.ingest(riding(40 + gap + TimeInterval(t))) }
        events += detector.finish()
        return events
    }

    func testARideSurvivesACutoffAndReconnect() {
        let events = ride(gap: 90)
        let ended = events.compactMap { event -> RideSummary? in
            if case .ended(let ride) = event { return ride } else { return nil }
        }
        XCTAssertEqual(events.filter { if case .started = $0 { return true } else { return false } }.count, 1)
        XCTAssertEqual(ended.count, 1, "the cutoff must not split the ride")
    }

    func testAGapAddsNoDistanceOrEnergy() throws {
        let events = ride(gap: 120)
        guard case .ended(let summary) = events.last else { return XCTFail("no ride end") }
        // 80 seconds of data at 20 km/h; the two minute gap adds nothing.
        XCTAssertEqual(summary.distanceKm, 20.0 / 3600 * 78, accuracy: 0.01)
    }

    func testAGapLongerThanFiveMinutesStillSplitsTheRide() {
        let started = ride(gap: 400).filter { if case .started = $0 { return true } else { return false } }
        XCTAssertEqual(started.count, 2)
    }
}

final class RegenDetectionTests: XCTestCase {
    func testBrakingWhileRollingIsRegeneration() {
        XCTAssertTrue(RegenDetection.isRegen(powerWatts: -100, speedKmh: 15))
        XCTAssertEqual(RegenDetection.recoveredWatts(powerWatts: -100, speedKmh: 15), 100)
    }

    func testNoiseAndStandstillAreNot() {
        XCTAssertFalse(RegenDetection.isRegen(powerWatts: -4, speedKmh: 15), "about +-4 W is what the controller reports at idle")
        XCTAssertFalse(RegenDetection.isRegen(powerWatts: -100, speedKmh: 1.5), "a lock holding the motor is not regeneration")
        XCTAssertFalse(RegenDetection.isRegen(powerWatts: 200, speedKmh: 20), "driving the motor is not regeneration")
        XCTAssertEqual(RegenDetection.recoveredWatts(powerWatts: -4, speedKmh: 15), 0)
    }

    func testTheThresholdsAreTheOnesTheDashboardShows() {
        XCTAssertEqual(RegenDetection.minimumSpeedKmh, 2.0)
        XCTAssertEqual(RegenDetection.minimumWatts, 5.0)
    }
}

final class RegenMeasurementTests: XCTestCase {
    private let origin = Date(timeIntervalSinceReferenceDate: 8_000_000)

    private func reading(_ seconds: TimeInterval, speed: Double = 20, volts: Double = 40, amps: Double = 5) -> TelemetrySample {
        TelemetrySample(date: origin.addingTimeInterval(seconds), speedKmh: speed, voltage: volts, current: amps,
                        batteryPercent: 80, controllerTemperature: 30, motorTemperature: 35)
    }

    private func ride(_ readings: [TelemetrySample]) -> RideSummary? {
        var detector = RideDetector()
        var events = readings.flatMap { detector.ingest($0) }
        events += detector.finish()
        return events.compactMap { if case .ended(let ride) = $0 { ride } else { nil } }.first
    }

    func testTheRecorderMeasuresRegenFromEveryReadingNotFromTheStoredSamples() throws {
        // Five readings per second: 20 s of pushing, then 10 s braking at -200 W (40 V, -5 A), then pushing again.
        var readings: [TelemetrySample] = []
        var t = 0.0
        while t < 20 { readings.append(reading(t)); t += 0.2 }
        while t < 30 { readings.append(reading(t, amps: -5)); t += 0.2 }
        while t < 50 { readings.append(reading(t)); t += 0.2 }
        let summary = try XCTUnwrap(ride(readings))
        // 200 W for about 10 s is 0.556 Wh. The first and last braking readings are half counted by the trapezoid.
        XCTAssertEqual(try XCTUnwrap(summary.regenWh), 200.0 * 10 / 3600, accuracy: 0.03)
    }

    func testNoBrakingMeansZeroRecovered() throws {
        let summary = try XCTUnwrap(ride((0..<200).map { reading(Double($0) * 0.2) }))
        XCTAssertEqual(try XCTUnwrap(summary.regenWh), 0, accuracy: 0.0001)
    }

    func testNoiseAroundZeroIsNotCountedAsRecovered() throws {
        // -0.1 A at 40 V is -4 W: the idle noise of the controller.
        let summary = try XCTUnwrap(ride((0..<200).map { reading(Double($0) * 0.2, amps: -0.1) }))
        XCTAssertEqual(try XCTUnwrap(summary.regenWh), 0, accuracy: 0.0001)
    }

    func testAGapInTheDataAddsNoRecoveredEnergy() throws {
        var readings = (0..<100).map { reading(Double($0) * 0.2) }
        readings.append(reading(200, amps: -5))   // a reading far away in time
        readings += (1..<100).map { reading(200 + Double($0) * 0.2, amps: -5) }
        let summary = try XCTUnwrap(ride(readings))
        XCTAssertLessThan(try XCTUnwrap(summary.regenWh), 200.0 * 20 / 3600 + 0.05, "only the 20 s actually recorded count")
    }

    func testMergedRidesAddUpTheirRecoveredEnergyAndUnknownStaysUnknown() {
        func summary(_ start: TimeInterval, regen: Double?) -> RideSummary {
            RideSummary(startedAt: Date(timeIntervalSinceReferenceDate: start), endedAt: Date(timeIntervalSinceReferenceDate: start + 60),
                        distanceKm: 1, averageSpeedKmh: 20, maxSpeedKmh: 25, energyWh: 5, batteryStart: 80, batteryEnd: 79,
                        maxControllerTemperature: 30, maxMotorTemperature: 35, internalResistanceOhm: nil, samples: [], regenWh: regen)
        }
        XCTAssertEqual(summary(100, regen: 1.5).merged(after: summary(0, regen: 2.0)).regenWh, 3.5)
        XCTAssertNil(summary(100, regen: 1.5).merged(after: summary(0, regen: nil)).regenWh, "an old ride without a measurement makes the total unknown")
    }
}

final class RideInsightsTests: XCTestCase {
    private func sample(_ t: TimeInterval, speed: Double = 20, power: Double = 200, battery: Int = 80) -> RideSample {
        RideSample(offset: t, speedKmh: speed, powerWatts: power, batteryPercent: battery, voltage: 40)
    }

    func testBrakingWithNegativePowerIsMarkedAsOneSegment() {
        let samples = [sample(0), sample(1, power: -100), sample(2, power: -200), sample(3, power: -100), sample(4)]
        XCTAssertEqual(RideInsights.regenSegments(in: samples), [RegenSegment(start: 1, end: 3)])
    }

    func testNoiseAndStandstillAreNotMarked() {
        XCTAssertTrue(RideInsights.regenSegments(in: [sample(0), sample(1, power: -3), sample(2, power: -4), sample(3)]).isEmpty)
        XCTAssertTrue(RideInsights.regenSegments(in: [sample(0, speed: 0, power: -50), sample(1, speed: 1, power: -50)]).isEmpty)
    }

    func testSeparateBrakingsAreSeparateSegmentsAndAGapSplitsOne() {
        let two = [sample(0, power: -50), sample(1, power: -50), sample(2), sample(3, power: -80), sample(4, power: -80)]
        XCTAssertEqual(RideInsights.regenSegments(in: two).count, 2)
        let gap = [sample(0, power: -50), sample(1, power: -50), sample(20, power: -50), sample(21, power: -50)]
        XCTAssertEqual(RideInsights.regenSegments(in: gap).count, 2, "a pause in the data is not one continuous braking")
    }

    func testASingleSampleIsMarkedForAboutOneSecond() {
        let segments = RideInsights.regenSegments(in: [sample(0), sample(5, power: -360), sample(10)])
        XCTAssertEqual(segments, [RegenSegment(start: 5, end: 6)])
    }

    func testTheEstimateUsesTheSameMathsAsTheRecorder() {
        // 360 W for one second between two samples is 0.1 Wh, and the transitions are half counted.
        let samples = [sample(0), sample(1, power: -360), sample(2, power: -360), sample(3)]
        XCTAssertEqual(RideInsights.estimatedRegenWh(in: samples), (180 + 360 + 180) / 3600.0, accuracy: 0.0001)
    }

    func testTheEstimateIgnoresGapsAndNoise() {
        XCTAssertEqual(RideInsights.estimatedRegenWh(in: [sample(0, power: -360), sample(100, power: -360)]), 0)
        XCTAssertEqual(RideInsights.estimatedRegenWh(in: [sample(0, power: -3), sample(1, power: -4)]), 0)
    }

    func testTheNearestSampleToAMomentIsFound() {
        let samples = [sample(0), sample(10), sample(20)]
        XCTAssertEqual(RideInsights.sample(at: 4, in: samples)?.offset, 0)
        XCTAssertEqual(RideInsights.sample(at: 6, in: samples)?.offset, 10)
        XCTAssertEqual(RideInsights.sample(at: -5, in: samples)?.offset, 0)
        XCTAssertEqual(RideInsights.sample(at: 99, in: samples)?.offset, 20)
        XCTAssertNil(RideInsights.sample(at: 5, in: []))
    }

    func testTheNearestRoutePointToATimeIsFound() {
        let origin = Date(timeIntervalSinceReferenceDate: 100)
        let dates = [0, 5, 10].map { origin.addingTimeInterval(Double($0)) }
        XCTAssertEqual(RideInsights.nearestIndex(to: origin.addingTimeInterval(4), in: dates), 1)
        XCTAssertEqual(RideInsights.nearestIndex(to: origin.addingTimeInterval(-9), in: dates), 0)
        XCTAssertEqual(RideInsights.nearestIndex(to: origin.addingTimeInterval(99), in: dates), 2)
        XCTAssertNil(RideInsights.nearestIndex(to: origin, in: []))
    }

    func testHighlightsFindTopSpeedAndPeakPower() {
        let samples = [sample(0, speed: 10, power: 100), sample(1, speed: 30, power: 900), sample(2, speed: 20, power: -60), sample(3, speed: 15, power: 50)]
        let highlights = RideInsights.highlights(in: samples)
        XCTAssertEqual(highlights.topSpeed?.offset, 1)
        XCTAssertEqual(highlights.peakPower?.offset, 1)
    }
}

final class SeriesDecimationTests: XCTestCase {
    func testShortSeriesAreLeftAlone() {
        XCTAssertEqual(SeriesDecimation.indices(of: [1, 2, 3], maximumPoints: 200), [0, 1, 2])
    }

    func testALongSeriesIsThinnedToTheLimit() {
        let values = (0..<10_000).map { sin(Double($0) / 50) }
        let indices = SeriesDecimation.indices(of: values, maximumPoints: 200)
        XCTAssertLessThanOrEqual(indices.count, 202)
        XCTAssertEqual(indices.first, 0)
        XCTAssertEqual(indices.last, 9_999)
        XCTAssertEqual(indices, indices.sorted())
        XCTAssertEqual(Set(indices).count, indices.count)
    }

    func testAShortPeakSurvivesThinning() {
        // Plain "every 50th point" would skip this one-sample spike and a one-sample dip.
        var values = [Double](repeating: 10, count: 10_000)
        values[4_321] = 99
        values[7_777] = -40
        let indices = Set(SeriesDecimation.indices(of: values, maximumPoints: 200))
        XCTAssertTrue(indices.contains(4_321), "the top speed must stay visible")
        XCTAssertTrue(indices.contains(7_777), "the hardest braking must stay visible")
    }
}

final class RideCuttingSettingsTests: XCTestCase {
    private let origin = Date(timeIntervalSinceReferenceDate: 9_500_000)

    private func summary(start: TimeInterval, duration: TimeInterval = 600) -> RideSummary {
        RideSummary(startedAt: origin.addingTimeInterval(start), endedAt: origin.addingTimeInterval(start + duration),
                    distanceKm: 1, averageSpeedKmh: 20, maxSpeedKmh: 25, energyWh: 5, batteryStart: 80, batteryEnd: 79,
                    maxControllerTemperature: 30, maxMotorTemperature: 35, internalResistanceOhm: nil, samples: [])
    }

    func testTheJoiningWindowIsConfigurable() {
        let first = summary(start: 0)
        let afterEightMinutes = summary(start: 600 + 8 * 60)
        XCTAssertFalse(afterEightMinutes.shouldMerge(after: first), "the default window is 5 minutes")
        XCTAssertTrue(afterEightMinutes.shouldMerge(after: first, within: 10 * 60))
        XCTAssertFalse(afterEightMinutes.shouldMerge(after: first, within: 2 * 60))
    }

    func testAWindowOfZeroTurnsJoiningOff() {
        let first = summary(start: 0)
        XCTAssertFalse(summary(start: 601).shouldMerge(after: first, within: 0))
    }

    func testTheDetectorFollowsAChangedStandingTime() {
        func sample(_ t: TimeInterval, speed: Double) -> TelemetrySample {
            TelemetrySample(date: origin.addingTimeInterval(t), speedKmh: speed, voltage: 40, current: speed > 0 ? 5 : 0,
                            batteryPercent: 80, controllerTemperature: 30, motorTemperature: 35)
        }
        var detector = RideDetector()
        var events: [RideDetector.Event] = []
        for t in 0..<60 { events += detector.ingest(sample(Double(t), speed: 20)) }
        // Standing still for 90 s ends the ride only if the standing time was shortened below that.
        var shorter = RideDetector.Configuration()
        shorter.stationaryTimeout = 60
        detector.update(configuration: shorter)
        for t in 60..<160 { events += detector.ingest(sample(Double(t), speed: 0)) }
        XCTAssertTrue(events.contains { if case .ended = $0 { true } else { false } }, "the shorter standing time ended the ride")
        XCTAssertFalse(detector.isRiding)
    }
}

final class RouteColoringTests: XCTestCase {
    private let origin = Date(timeIntervalSinceReferenceDate: 9_900_000)

    private func samples(speedAt: (Double) -> Double, seconds: Int = 600) -> [RideSample] {
        (0...seconds).map { RideSample(offset: Double($0), speedKmh: speedAt(Double($0)), powerWatts: 100, batteryPercent: 80, voltage: 40) }
    }

    private func dates(count: Int, every seconds: Double = 5) -> [Date] {
        (0..<count).map { origin.addingTimeInterval(Double($0) * seconds) }
    }

    func testEachStretchGetsTheSpeedFromItsOwnTime() {
        // Slow for the first half of the ride, fast for the second.
        let slowThenFast = samples(speedAt: { $0 < 300 ? 8 : 24 })
        let segments = RouteColoring.segments(dates: dates(count: 121), startedAt: origin, samples: slowThenFast, maximumSegments: 4)
        XCTAssertEqual(segments.map(\.speedKmh), [8, 8, 24, 24])
    }

    func testStretchesShareTheirEndPointsSoTheRouteHasNoGaps() {
        let segments = RouteColoring.segments(dates: dates(count: 101), startedAt: origin, samples: samples(speedAt: { _ in 15 }), maximumSegments: 10)
        XCTAssertEqual(segments.first?.first, 0)
        XCTAssertEqual(segments.last?.last, 100)
        for (a, b) in zip(segments, segments.dropFirst()) { XCTAssertEqual(a.last, b.first) }
    }

    func testALongRouteIsCutToTheLimit() {
        let segments = RouteColoring.segments(dates: dates(count: 20_000, every: 0.5), startedAt: origin, samples: samples(speedAt: { _ in 15 }, seconds: 10_000), maximumSegments: 150)
        XCTAssertLessThanOrEqual(segments.count, 150)
        XCTAssertEqual(segments.last?.last, 19_999)
    }

    func testAShortRouteKeepsEveryPoint() {
        let segments = RouteColoring.segments(dates: dates(count: 5), startedAt: origin, samples: samples(speedAt: { _ in 15 }), maximumSegments: 150)
        XCTAssertEqual(segments.count, 4)
    }

    func testTooLittleDataGivesNoSegmentsInsteadOfACrash() {
        XCTAssertTrue(RouteColoring.segments(dates: [], startedAt: origin, samples: []).isEmpty)
        XCTAssertTrue(RouteColoring.segments(dates: dates(count: 1), startedAt: origin, samples: []).isEmpty)
        XCTAssertEqual(RouteColoring.segments(dates: dates(count: 3), startedAt: origin, samples: []).map(\.speedKmh), [0, 0], "without samples the speed is unknown, shown as zero")
    }

    func testTheNearestRoutePointToATapIsFound() {
        let points: [(latitude: Double, longitude: Double)] = [(52.000, 13.000), (52.001, 13.000), (52.002, 13.000)]
        XCTAssertEqual(RouteColoring.nearestPoint(toLatitude: 52.0012, longitude: 13.0001, in: points), 1)
        XCTAssertEqual(RouteColoring.nearestPoint(toLatitude: 51.9, longitude: 13.0, in: points), 0)
        XCTAssertEqual(RouteColoring.nearestPoint(toLatitude: 52.5, longitude: 13.0, in: points), 2)
        XCTAssertNil(RouteColoring.nearestPoint(toLatitude: 52, longitude: 13, in: []))
    }

    func testLongitudeDistanceShrinksTowardsThePoles() {
        // At 60 degrees north a degree of longitude is half as long as a degree of latitude.
        let points: [(latitude: Double, longitude: Double)] = [(60.0, 10.0), (60.0006, 10.0)]
        // 0.0004 degrees north of the first point is closer to the second one than 0.0004 degrees east is.
        XCTAssertEqual(RouteColoring.nearestPoint(toLatitude: 60.0004, longitude: 10.0, in: points), 1)
        XCTAssertEqual(RouteColoring.nearestPoint(toLatitude: 60.0, longitude: 10.0006, in: points), 0, "0.0006 east is only about 0.0003 of ground")
    }
}

final class BatteryModelTests: XCTestCase {
    func testNominalCapacityMatchesTheManual() {
        XCTAssertEqual(BatteryModel.nominalCapacityWh, 342, accuracy: 1e-9)
    }

    func testStateOfChargeFollowsTheCellCurve() {
        XCTAssertEqual(BatteryModel.stateOfCharge(openCircuitVoltage: 42.0), 100, accuracy: 1e-9)
        XCTAssertEqual(BatteryModel.stateOfCharge(openCircuitVoltage: 38.4), 50, accuracy: 1e-9)
        XCTAssertEqual(BatteryModel.stateOfCharge(openCircuitVoltage: 45), 100)
        XCTAssertEqual(BatteryModel.stateOfCharge(openCircuitVoltage: 30), 0)
        let low = BatteryModel.stateOfCharge(openCircuitVoltage: 38.0)
        let high = BatteryModel.stateOfCharge(openCircuitVoltage: 39.0)
        XCTAssertLessThan(low, high)
    }

    func testLoadSagIsAddedBack() {
        let rested = BatteryModel.openCircuitVoltage(terminal: 37.6, current: 10, resistanceOhm: 0.18)
        XCTAssertEqual(rested, 39.4, accuracy: 1e-9)
        XCTAssertEqual(BatteryModel.openCircuitVoltage(terminal: 40, current: -2, resistanceOhm: 0.18), 39.64, accuracy: 1e-9)
    }

    func testHealthAndChargeTime() {
        XCTAssertEqual(BatteryModel.stateOfHealth(capacityWh: 307.8), 90, accuracy: 1e-9)
        XCTAssertEqual(BatteryModel.hoursToFull(percent: 100, capacityWh: 342), 0)
        let full = BatteryModel.hoursToFull(percent: 0, capacityWh: 342)
        XCTAssertGreaterThan(full, 4)
        XCTAssertLessThan(full, 6.5, "close to the 5.75 h in the manual")
        XCTAssertLessThan(BatteryModel.hoursToFull(percent: 50, capacityWh: 342), full)
    }
}


final class ChargeCycleTests: XCTestCase {
    private let origin = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func ride(_ day: Double, from: Int, to: Int, km: Double = 5, wh: Double = 60, regen: Double? = 5) -> ChargeCycles.Ride {
        let start = origin.addingTimeInterval(day * 86_400)
        return ChargeCycles.Ride(
            startedAt: start, endedAt: start.addingTimeInterval(900), distanceKm: km, energyWh: wh,
            batteryStart: from, batteryEnd: to, maxSpeedKmh: 24, regenWh: regen
        )
    }

    func testRidesThatKeepDrainingTheBatteryAreOneCycle() {
        let cycles = ChargeCycles.cycles(from: [ride(0, from: 98, to: 90), ride(1, from: 90, to: 80), ride(2, from: 79, to: 70)])
        XCTAssertEqual(cycles.count, 1)
        XCTAssertEqual(cycles[0].rideCount, 3)
        XCTAssertEqual(cycles[0].distanceKm, 15, accuracy: 0.0001)
        XCTAssertEqual(cycles[0].startPercent, 98)
        XCTAssertEqual(cycles[0].endPercent, 70)
        XCTAssertEqual(cycles[0].usedPercent, 28)
    }

    func testARiseOfEightPointsOrMoreBetweenRidesStartsANewCycle() {
        let rides = [ride(0, from: 98, to: 40), ride(1, from: 44, to: 30), ride(3, from: 100, to: 60)]
        let cycles = ChargeCycles.cycles(from: rides)
        XCTAssertEqual(cycles.map(\.rideCount), [2, 1])
        XCTAssertEqual(cycles.map(\.number), [1, 2])
        XCTAssertEqual(cycles[0].endPercent, 30)
        XCTAssertEqual(cycles[1].startPercent, 100)
        XCTAssertEqual(ChargeCycles.cycles(from: [ride(0, from: 98, to: 40), ride(1, from: 47, to: 30)]).count, 1, "seven points is noise, not a charge")
        XCTAssertEqual(ChargeCycles.cycles(from: [ride(0, from: 98, to: 40), ride(1, from: 48, to: 30)]).count, 2, "eight points is a charge")
    }

    func testRidesAreOrderedByTimeWhateverTheInput() {
        let cycles = ChargeCycles.cycles(from: [ride(3, from: 100, to: 60), ride(0, from: 98, to: 40)])
        XCTAssertEqual(cycles.map(\.startPercent), [98, 100])
    }

    func testTotalsRangeAndRecoveredEnergy() {
        let cycles = ChargeCycles.cycles(from: [ride(0, from: 100, to: 70, km: 10, wh: 100, regen: 8), ride(1, from: 70, to: 50, km: 8, wh: 80, regen: 6)])
        let cycle = cycles[0]
        XCTAssertEqual(cycle.energyWh, 180, accuracy: 0.0001)
        XCTAssertEqual(cycle.whPerKm ?? 0, 10, accuracy: 0.0001)
        XCTAssertEqual(cycle.ridingTime, 1800, accuracy: 0.0001)
        XCTAssertEqual(cycle.regenWh ?? 0, 14, accuracy: 0.0001)
        XCTAssertEqual(cycle.projectedRangeKm ?? 0, 36, accuracy: 0.0001, "18 km on 50 % is 36 km on a full battery")
        XCTAssertNil(ChargeCycles.cycles(from: [ride(0, from: 80, to: 70)])[0].projectedRangeKm, "ten points is too little to extrapolate from")
    }

    func testRecoveredEnergyIsUnknownIfAnyRideDidNotMeasureIt() {
        XCTAssertNil(ChargeCycles.cycles(from: [ride(0, from: 90, to: 80, regen: 4), ride(1, from: 80, to: 70, regen: nil)])[0].regenWh)
    }

    func testNoRidesMeansNoCycles() {
        XCTAssertTrue(ChargeCycles.cycles(from: []).isEmpty)
    }

    func testAHigherLevelNowThanAtTheEndOfTheLastRideMeansItWasCharged() {
        XCTAssertTrue(ChargeCycles.isChargedSinceLastRide(lastRideEnd: 30, currentPercent: 95))
        XCTAssertFalse(ChargeCycles.isChargedSinceLastRide(lastRideEnd: 30, currentPercent: 33))
    }
}

final class ChargeBasedCapacityTests: XCTestCase {
    private func ride(_ from: Int, _ to: Int, wh: Double, km: Double = 5) -> RideEnergyRecord {
        RideEnergyRecord(distanceKm: km, energyWh: wh, batteryStart: from, batteryEnd: to)
    }

    func testCapacityIsTheEnergyOfWholeChargesOverTheBatteryTheyUsed() throws {
        // Two charges, newest first. Each used 100 → 40, 60 points, for 200 Wh: 333 Wh for a full pack.
        let rides = [ride(70, 40, wh: 100), ride(100, 70, wh: 100), ride(68, 38, wh: 100), ride(98, 68, wh: 100)]
        let model = try XCTUnwrap(RangeEstimator.model(rides: rides, manualCapacityWh: nil, nominalCapacityWh: 342))
        XCTAssertEqual(model.capacityWh, 400.0 / 1.20, accuracy: 1e-9)
        XCTAssertEqual(model.calibrationCycles, 2)
        XCTAssertTrue(model.isCapacityCalibrated)
    }

    func testSmallDrainsAreNotTrustedForTheCapacity() throws {
        // Charges that each used only 6 points: too coarse for either method, so the rating is kept.
        let rides = [ride(95, 89, wh: 20), ride(96, 90, wh: 20), ride(97, 91, wh: 20), ride(95, 89, wh: 20)]
        let model = try XCTUnwrap(RangeEstimator.model(rides: rides, manualCapacityWh: nil, nominalCapacityWh: 342))
        XCTAssertEqual(model.capacityWh, 342)
        XCTAssertEqual(model.calibrationCycles, 0)
    }

    func testRidesOfOneChargeAreJoinedBeforeTheyAreJudged() throws {
        // Three 10-point rides in a row are one 30-point charge, which is enough; alone none of them is.
        let rides = [ride(70, 60, wh: 35), ride(80, 70, wh: 35), ride(90, 80, wh: 35)]
        let found = try XCTUnwrap(RangeEstimator.capacityFromCharges(rides))
        XCTAssertEqual(found.cycles, 1)
        XCTAssertEqual(found.capacityWh, 105.0 / 0.30, accuracy: 1e-9)
    }

    func testOnlyTheNewestChargesCount() throws {
        var rides: [RideEnergyRecord] = []
        for _ in 0..<6 { rides.append(ride(100, 60, wh: 120)) }   // 300 Wh packs
        rides.append(ride(100, 60, wh: 240))                      // an old, oddly high one: 600 Wh
        let found = try XCTUnwrap(RangeEstimator.capacityFromCharges(rides))
        XCTAssertEqual(found.cycles, RangeEstimator.calibrationCycleLimit)
        XCTAssertEqual(found.capacityWh, 300, accuracy: 1e-9)
    }

    func testAManualCapacityStillWins() throws {
        let rides = [ride(100, 40, wh: 200), ride(100, 40, wh: 200)]
        let model = try XCTUnwrap(RangeEstimator.model(rides: rides, manualCapacityWh: 400, nominalCapacityWh: 342))
        XCTAssertEqual(model.capacityWh, 400)
        XCTAssertEqual(model.calibrationCycles, 0)
    }
}
