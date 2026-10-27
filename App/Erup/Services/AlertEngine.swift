import Foundation

/// Checks the rules against each reading. Every rule fires once when its condition is met and again only after the
/// reading has come back by its margin, so a value hovering at a threshold gives one alert.
struct AlertEngine {
    enum Alert: Equatable {
        case rule(AlertRule, value: Double)
        case chargeComplete
    }

    struct Reading {
        var batteryPercent: Int
        var controllerTemperature: Int
        var motorTemperature: Int
        var current: Double
        var speedKmh: Double
        var isConnected: Bool
        var date: Date
    }

    static let chargingCurrent = -0.2
    static let chargingDuration: TimeInterval = 30
    static let fullBattery = 100

    private var armed: [UUID: Bool] = [:]
    private var chargeArmed = true
    private var chargingSince: Date?

    mutating func evaluate(_ reading: Reading, rules: [AlertRule], notifiesChargeComplete: Bool = true) -> [Alert] {
        guard reading.isConnected else {
            chargingSince = nil
            return []
        }
        var alerts: [Alert] = []

        var triggered: [(rule: AlertRule, value: Double)] = []
        for rule in rules {
            guard rule.isEnabled else {
                armed[rule.id] = true
                continue
            }
            let value = rule.metric.value(in: reading)
            if rule.isMet(by: value) {
                if armed[rule.id] ?? true { triggered.append((rule, value)) }
            } else if rule.hasReset(at: value) {
                armed[rule.id] = true
            }
        }
        // Rules on the same reading that fire together, such as low and critical battery, give one alert: the most serious.
        for rule in triggered { armed[rule.rule.id] = false }
        var groups: [String: (rule: AlertRule, value: Double)] = [:]
        for item in triggered {
            let key = "\(item.rule.metric.rawValue).\(item.rule.direction.rawValue)"
            if let best = groups[key], !Self.isMoreSpecific(item.rule, than: best.rule) { continue }
            groups[key] = item
        }
        for rule in rules {
            if let item = groups.values.first(where: { $0.rule.id == rule.id }) { alerts.append(.rule(item.rule, value: item.value)) }
        }

        let isCharging = reading.current <= Self.chargingCurrent && reading.speedKmh < 0.5
        if isCharging {
            chargingSince = chargingSince ?? reading.date
        } else if reading.current > 0 {
            chargingSince = nil
        }
        if notifiesChargeComplete, let chargingSince, chargeArmed, reading.batteryPercent >= Self.fullBattery,
           reading.date.timeIntervalSince(chargingSince) >= Self.chargingDuration {
            chargeArmed = false
            alerts.append(.chargeComplete)
        }
        if reading.batteryPercent < 95 { chargeArmed = true }
        return alerts
    }

    /// The more serious rule wins; between two equally serious ones, the one with the further threshold.
    private static func isMoreSpecific(_ rule: AlertRule, than other: AlertRule) -> Bool {
        if rule.severity != other.severity { return rule.severity > other.severity }
        return rule.direction == .above ? rule.threshold > other.threshold : rule.threshold < other.threshold
    }
}
