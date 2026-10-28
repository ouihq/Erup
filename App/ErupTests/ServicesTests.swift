import SwiftUI
import XCTest
@testable import Erup

final class AlertEngineTests: XCTestCase {
    private let rules = AlertRule.defaults

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

    private func names(_ alerts: [AlertEngine.Alert]) -> [String] {
        alerts.map { if case .rule(let rule, _) = $0 { rule.name } else { "charge complete" } }
    }

    func testLowBatteryFiresOnceAndRearmsWithHysteresis() {
        var engine = AlertEngine()
        XCTAssertEqual(names(engine.evaluate(reading(battery: 21), rules: rules)), [])
        XCTAssertEqual(names(engine.evaluate(reading(battery: 20), rules: rules)), ["Battery low"])
        XCTAssertEqual(names(engine.evaluate(reading(battery: 19), rules: rules)), [])
        XCTAssertEqual(names(engine.evaluate(reading(battery: 22), rules: rules)), [])
        XCTAssertEqual(names(engine.evaluate(reading(battery: 20), rules: rules)), [])
        _ = engine.evaluate(reading(battery: 26), rules: rules)
        XCTAssertEqual(names(engine.evaluate(reading(battery: 20), rules: rules)), ["Battery low"])
    }

    func testCriticalSupersedesLowWhenTheyFireTogether() {
        var engine = AlertEngine()
        XCTAssertEqual(names(engine.evaluate(reading(battery: 9), rules: rules)), ["Battery critical"])
        XCTAssertEqual(names(engine.evaluate(reading(battery: 8), rules: rules)), [])
    }

    func testLowThenCriticalAreTwoAlertsAsTheBatteryFalls() {
        var engine = AlertEngine()
        XCTAssertEqual(names(engine.evaluate(reading(battery: 20), rules: rules)), ["Battery low"])
        XCTAssertEqual(names(engine.evaluate(reading(battery: 10), rules: rules)), ["Battery critical"])
    }

    func testTemperatureAlertsRearmBelowHysteresis() {
        var engine = AlertEngine()
        XCTAssertEqual(names(engine.evaluate(reading(controller: 71), rules: rules)), ["Controller warm"])
        XCTAssertEqual(names(engine.evaluate(reading(controller: 72), rules: rules)), [])
        XCTAssertEqual(names(engine.evaluate(reading(controller: 65), rules: rules)), [])
        _ = engine.evaluate(reading(controller: 55), rules: rules)
        XCTAssertEqual(names(engine.evaluate(reading(controller: 71), rules: rules)), ["Controller warm"])
        XCTAssertEqual(names(engine.evaluate(reading(motor: 82), rules: rules)), ["Motor warm"])
    }

    func testTheYellowLevelComesFirstAndTheRedOneTakesOverAsItKeepsHeatingUp() {
        var engine = AlertEngine()
        XCTAssertEqual(names(engine.evaluate(reading(controller: 72), rules: rules)), ["Controller warm"])
        XCTAssertEqual(names(engine.evaluate(reading(controller: 86), rules: rules)), ["Controller hot"])
        XCTAssertEqual(names(engine.evaluate(reading(motor: 82), rules: rules)), ["Motor warm"])
        XCTAssertEqual(names(engine.evaluate(reading(motor: 101), rules: rules)), ["Motor hot"])
    }

    func testACustomRuleFiresAboveItsThresholdAndCarriesItsValue() {
        var engine = AlertEngine()
        let warm = AlertRule(name: "Motor warm", metric: .motorTemperature, direction: .above, threshold: 60, severity: .warning)
        let custom = rules + [warm]
        XCTAssertEqual(names(engine.evaluate(reading(motor: 59), rules: custom)), [])
        let alerts = engine.evaluate(reading(motor: 62), rules: custom)
        XCTAssertEqual(alerts, [.rule(warm, value: 62)])
        XCTAssertEqual(names(engine.evaluate(reading(motor: 64), rules: custom)), [])
        _ = engine.evaluate(reading(motor: 45), rules: custom)
        XCTAssertEqual(names(engine.evaluate(reading(motor: 61), rules: custom)), ["Motor warm"])
    }

    func testTwoRulesOnTheSameReadingGiveTheMoreSeriousOne() {
        var engine = AlertEngine()
        let warm = AlertRule(name: "Motor warm of my own", metric: .motorTemperature, direction: .above, threshold: 60, severity: .warning)
        XCTAssertEqual(names(engine.evaluate(reading(motor: 105), rules: rules + [warm])), ["Motor hot"])
    }

    func testSpeedAndCurrentRules() {
        var engine = AlertEngine()
        let fast = AlertRule(name: "Too fast", metric: .speed, direction: .above, threshold: 25, severity: .info)
        let heavy = AlertRule(name: "Heavy load", metric: .current, direction: .above, threshold: 12, severity: .warning)
        XCTAssertEqual(names(engine.evaluate(reading(current: 13, speed: 26), rules: [fast, heavy])), ["Too fast", "Heavy load"])
    }

    func testADisabledRuleNeverFires() {
        var engine = AlertEngine()
        var low = rules[0]
        low.isEnabled = false
        XCTAssertEqual(names(engine.evaluate(reading(battery: 15), rules: [low])), [])
    }

    func testChargeCompleteNeedsSustainedChargingThenFullBattery() {
        var engine = AlertEngine()
        XCTAssertEqual(engine.evaluate(reading(battery: 98, current: -1, speed: 0, at: 0), rules: rules), [])
        XCTAssertEqual(engine.evaluate(reading(battery: 100, current: -0.5, speed: 0, at: 10), rules: rules), [])
        XCTAssertEqual(engine.evaluate(reading(battery: 100, current: -0.3, speed: 0, at: 40), rules: rules), [.chargeComplete])
        XCTAssertEqual(engine.evaluate(reading(battery: 100, current: -0.3, speed: 0, at: 80), rules: rules), [])
    }

    func testChargeCompleteCanBeSwitchedOff() {
        var engine = AlertEngine()
        _ = engine.evaluate(reading(battery: 100, current: -0.5, speed: 0, at: 0), rules: rules, notifiesChargeComplete: false)
        XCTAssertEqual(engine.evaluate(reading(battery: 100, current: -0.3, speed: 0, at: 60), rules: rules, notifiesChargeComplete: false), [])
    }

    func testFullBatteryWithoutChargingDoesNotNotify() {
        var engine = AlertEngine()
        XCTAssertEqual(engine.evaluate(reading(battery: 100, current: 0, speed: 0, at: 100), rules: rules), [])
    }

    func testDisconnectedProducesNoAlerts() {
        var engine = AlertEngine()
        XCTAssertEqual(engine.evaluate(reading(battery: 5, connected: false), rules: rules), [])
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

@MainActor
final class AlertRuleTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let suite = "alert-rules-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    func testNothingStoredGivesTheStandardRulesYellowThenRed() {
        let rules = AlertRuleStorage.rules(in: defaults())
        XCTAssertEqual(rules, AlertRule.defaults)
        let battery = rules.filter { $0.metric == .battery }
        XCTAssertEqual(battery.map(\.threshold), [20, 10])
        XCTAssertEqual(battery.map(\.severity), [.warning, .critical])
    }

    func testLevelsChosenBeforeAlertsWereRulesAreKept() {
        let stored = defaults()
        stored.set(30, forKey: "alerts.batteryLow")
        stored.set(0, forKey: "alerts.motorHot")
        let rules = AlertRuleStorage.rules(in: stored)
        XCTAssertEqual(rules.first { $0.id == AlertRule.batteryLowID }?.threshold, 30)
        XCTAssertEqual(rules.first { $0.id == AlertRule.motorHotID }?.isEnabled, false)
    }

    func testRulesRoundTripThroughTheSettings() {
        let stored = defaults()
        let custom = AlertRule(name: "Motor warm", metric: .motorTemperature, direction: .above, threshold: 60, severity: .warning, notifies: false)
        AlertRuleStorage.save(AlertRule.defaults + [custom], in: stored)
        XCTAssertEqual(AlertRuleStorage.rules(in: stored).last, custom)
        XCTAssertNotNil(stored.string(forKey: "alerts.rules"), "one string, so a backup carries it")
    }

    func testTheCenterSavesEditsAndKeepsBuiltInsFromBeingDeleted() {
        let stored = defaults()
        let center = AlertRuleCenter(defaults: stored)
        var low = center.rules[0]
        low.threshold = 25
        center.update(low)
        let custom = AlertRule(name: "Fast", metric: .speed, direction: .above, threshold: 30)
        center.update(custom)
        center.delete(low)
        XCTAssertEqual(center.rules.count, AlertRule.defaults.count + 1, "a built-in rule can only be switched off")
        center.delete(custom)
        XCTAssertEqual(AlertRuleCenter(defaults: stored).rules.first?.threshold, 25)
        XCTAssertEqual(AlertRuleCenter(defaults: stored).rules.count, AlertRule.defaults.count)
    }

    func testAChangeMadeElsewhereIsPickedUp() {
        let stored = defaults()
        let center = AlertRuleCenter(defaults: stored)
        var rules = center.rules
        rules[1].threshold = 7
        AlertRuleStorage.save(rules, in: stored)
        center.reloadIfChanged()
        XCTAssertEqual(center.rules[1].threshold, 7)
    }

    func testTheIndicatorTakesTheMostSeriousRuleThatIsMet() {
        let center = AlertRuleCenter(defaults: defaults())
        XCTAssertNil(center.severity(for: .battery, value: 50))
        XCTAssertEqual(center.severity(for: .battery, value: 20), .warning)
        XCTAssertEqual(center.severity(for: .battery, value: 10), .critical)
        XCTAssertNil(center.severity(for: .motorTemperature, value: 50))
        XCTAssertEqual(center.severity(for: .motorTemperature, value: 85), .warning)
        XCTAssertEqual(center.severity(for: .motorTemperature, value: 105), .critical)
    }

    func testRulesAreReadableAsText() {
        XCTAssertEqual(AlertRule.defaults[0].summary, "Battery at or below 20%")
        XCTAssertEqual(AlertRule.defaults.last?.summary, "Motor temperature at or above 100 °C")
    }

    func testEachTemperatureHasAYellowLevelBelowItsRedOne() {
        for metric in [AlertMetric.controllerTemperature, .motorTemperature] {
            let levels = AlertRule.defaults.filter { $0.metric == metric }
            XCTAssertEqual(levels.map(\.severity), [.warning, .critical], metric.title)
            XCTAssertLessThan(levels[0].threshold, levels[1].threshold, metric.title)
            XCTAssertFalse(levels[0].notifies, "the yellow level stays in the app")
            XCTAssertTrue(levels[1].notifies, "the red one notifies")
        }
    }

    func testWhatTheEditorOffersCoversEveryStandardAlert() {
        for metric in AlertMetric.allCases {
            XCTAssertTrue(metric.range.contains(metric.defaultThreshold), metric.title)
            XCTAssertFalse(metric.presets.isEmpty, metric.title)
            XCTAssertTrue(metric.presets.allSatisfy(metric.range.contains), metric.title)
            XCTAssertEqual(metric.presets, metric.presets.sorted(), metric.title)
        }
        for rule in AlertRule.defaults {
            XCTAssertTrue(rule.metric.range.contains(rule.threshold), rule.name)
        }
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
