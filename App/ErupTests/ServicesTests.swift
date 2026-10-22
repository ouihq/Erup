import SwiftUI
import XCTest
@testable import Erup

final class AlertEngineTests: XCTestCase {
    private func reading(
        battery: Int = 80, controller: Int = 30, motor: Int = 30, current: Double = 1,
        speed: Double = 10, connected: Bool = true, at seconds: TimeInterval = 0
    ) -> AlertEngine.Reading {
        .init(
            batteryPercent: battery, controllerTemperature: controller, motorTemperature: motor,
            current: current, speedKmh: speed, isConnected: connected,
            date: Date(timeIntervalSinceReferenceDate: seconds)
        )
    }

    func testLowBatteryFiresOnceAndRearmsWithHysteresis() {
        var engine = AlertEngine()
        XCTAssertEqual(engine.evaluate(reading(battery: 21)), [])
        XCTAssertEqual(engine.evaluate(reading(battery: 20)), [.batteryLow(20)])
        XCTAssertEqual(engine.evaluate(reading(battery: 19)), [])
        XCTAssertEqual(engine.evaluate(reading(battery: 22)), [])
        XCTAssertEqual(engine.evaluate(reading(battery: 20)), [])
        _ = engine.evaluate(reading(battery: 26))
        XCTAssertEqual(engine.evaluate(reading(battery: 20)), [.batteryLow(20)])
    }

    func testCriticalSupersedesLow() {
        var engine = AlertEngine()
        XCTAssertEqual(engine.evaluate(reading(battery: 9)), [.batteryCritical(9)])
        XCTAssertEqual(engine.evaluate(reading(battery: 8)), [])
    }

    func testTemperatureAlertsRearmBelowHysteresis() {
        var engine = AlertEngine()
        XCTAssertEqual(engine.evaluate(reading(controller: 71)), [.controllerHot(71)])
        XCTAssertEqual(engine.evaluate(reading(controller: 72)), [])
        XCTAssertEqual(engine.evaluate(reading(controller: 65)), [])
        _ = engine.evaluate(reading(controller: 55))
        XCTAssertEqual(engine.evaluate(reading(controller: 71)), [.controllerHot(71)])
        XCTAssertEqual(engine.evaluate(reading(motor: 95)), [.motorHot(95)])
    }

    func testChargeCompleteNeedsSustainedChargingThenFullBattery() {
        var engine = AlertEngine()
        XCTAssertEqual(engine.evaluate(reading(battery: 98, current: -1, speed: 0, at: 0)), [])
        XCTAssertEqual(engine.evaluate(reading(battery: 100, current: -0.5, speed: 0, at: 10)), [])
        XCTAssertEqual(engine.evaluate(reading(battery: 100, current: -0.3, speed: 0, at: 40)), [.chargeComplete])
        XCTAssertEqual(engine.evaluate(reading(battery: 100, current: -0.3, speed: 0, at: 80)), [])
    }

    func testFullBatteryWithoutChargingDoesNotNotify() {
        var engine = AlertEngine()
        XCTAssertEqual(engine.evaluate(reading(battery: 100, current: 0, speed: 0, at: 100)), [])
    }

    func testDisconnectedProducesNoAlerts() {
        var engine = AlertEngine()
        XCTAssertEqual(engine.evaluate(reading(battery: 5, connected: false)), [])
    }
}

final class UpdatePolicyTests: XCTestCase {
    private func state(
        speed: Int = 10, battery: Int = 80, gear: UInt8 = 1, light: Bool = false, connected: Bool = true, trip: Double = 1
    ) -> ScooterActivityAttributes.ContentState {
        .init(speedKmh: speed, batteryPercent: battery, rangeKm: nil, gearRaw: gear, tripKm: trip,
              headlightOn: light, isConnected: connected, usesMiles: false)
    }

    func testFirstStateAlwaysUpdates() {
        XCTAssertTrue(ActivityUpdatePolicy.shouldUpdate(from: nil, to: state(), secondsSinceLastUpdate: 0))
    }

    func testSpeedChangesAreRateLimited() {
        XCTAssertFalse(ActivityUpdatePolicy.shouldUpdate(from: state(speed: 10), to: state(speed: 12), secondsSinceLastUpdate: 1))
        XCTAssertTrue(ActivityUpdatePolicy.shouldUpdate(from: state(speed: 10), to: state(speed: 12), secondsSinceLastUpdate: 3))
    }

    func testIdenticalStateNeverUpdates() {
        XCTAssertFalse(ActivityUpdatePolicy.shouldUpdate(from: state(), to: state(), secondsSinceLastUpdate: 60))
    }

    func testStructuralChangesGoThroughQuickly() {
        XCTAssertTrue(ActivityUpdatePolicy.shouldUpdate(from: state(), to: state(gear: 2), secondsSinceLastUpdate: 1))
        XCTAssertTrue(ActivityUpdatePolicy.shouldUpdate(from: state(), to: state(connected: false), secondsSinceLastUpdate: 1))
        XCTAssertFalse(ActivityUpdatePolicy.shouldUpdate(from: state(), to: state(battery: 79), secondsSinceLastUpdate: 0.2))
    }
}

final class SnapshotTests: XCTestCase {
    func testSnapshotRoundTripsThroughJSON() throws {
        let data = try JSONEncoder().encode(ScooterSnapshot.preview)
        XCTAssertEqual(try JSONDecoder().decode(ScooterSnapshot.self, from: data), .preview)
    }

    func testStructuralChangeIgnoresSpeedOnly() {
        var changed = ScooterSnapshot.preview
        changed.speedKmh += 3
        XCTAssertFalse(SnapshotWriter.hasStructuralChange(from: .preview, to: changed))
        changed.headlightOn.toggle()
        XCTAssertTrue(SnapshotWriter.hasStructuralChange(from: .preview, to: changed))
        XCTAssertTrue(SnapshotWriter.hasStructuralChange(from: nil, to: .preview))
    }
}

final class AlertSettingsTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let suite = "alert-settings-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func reading(battery: Int = 80, controller: Int = 30, motor: Int = 30) -> AlertEngine.Reading {
        .init(batteryPercent: battery, controllerTemperature: controller, motorTemperature: motor, current: 1, speedKmh: 10, isConnected: true, date: .now)
    }

    func testNothingStoredGivesTheStandardLimits() {
        XCTAssertEqual(AlertSettings.limits(in: defaults()), .standard)
    }

    func testStoredChoicesAreUsedAndZeroSwitchesAnAlertOff() {
        let defaults = defaults()
        defaults.set(30, forKey: AlertSettings.batteryLow.key)
        defaults.set(0, forKey: AlertSettings.motorHot.key)
        defaults.set(false, forKey: AlertSettings.chargeCompleteKey)
        let limits = AlertSettings.limits(in: defaults)
        XCTAssertEqual(limits.batteryLow, 30)
        XCTAssertNil(limits.motorHot)
        XCTAssertFalse(limits.chargeComplete)
    }

    func testAValueOutsideTheChoicesFallsBackToTheDefault() {
        let defaults = defaults()
        defaults.set(37, forKey: AlertSettings.controllerHot.key)
        XCTAssertEqual(AlertSettings.limits(in: defaults).controllerHot, 70)
    }

    func testTheEngineFollowsTheLimitsItIsGiven() {
        var engine = AlertEngine()
        var limits = AlertEngine.Limits.standard
        limits.controllerHot = 60
        limits.motorHot = nil
        XCTAssertEqual(engine.evaluate(reading(controller: 61, motor: 120), limits: limits), [.controllerHot(61)])
        limits.batteryLow = 40
        XCTAssertEqual(engine.evaluate(reading(battery: 40), limits: limits), [.batteryLow(40)])
        limits.batteryLow = nil
        var quiet = AlertEngine()
        XCTAssertEqual(quiet.evaluate(reading(battery: 15), limits: limits), [])
    }
}

final class RideDisplaySettingsTests: XCTestCase {
    func testASwitchAddsAndRemovesAName() {
        var stored = ""
        let list = Binding(get: { stored }, set: { stored = $0 })
        let binding = RideDisplaySettings.binding(list, name: "Elevation")
        XCTAssertFalse(binding.wrappedValue)
        binding.wrappedValue = true
        XCTAssertEqual(stored, "Elevation")
        binding.wrappedValue = false
        XCTAssertEqual(stored, "")
    }
}
