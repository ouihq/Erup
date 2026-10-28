import Foundation
import Observation
import SwiftUI

/// What a rule watches. Each is a reading the app already has with every update, so checking a rule costs a comparison.
enum AlertMetric: String, Codable, CaseIterable, Identifiable, Sendable {
    case battery, motorTemperature, controllerTemperature, speed, current

    var id: String { rawValue }

    var title: String {
        switch self {
        case .battery: "Battery"
        case .motorTemperature: "Motor temperature"
        case .controllerTemperature: "Controller temperature"
        case .speed: "Speed"
        case .current: "Current"
        }
    }

    var symbol: String {
        switch self {
        case .battery: "battery.50percent"
        case .motorTemperature: "gearshape.2.fill"
        case .controllerTemperature: "cpu.fill"
        case .speed: "gauge.with.needle.fill"
        case .current: "bolt.fill"
        }
    }

    /// The unit the threshold is stored in. Speed is shown in the rider's unit but kept in km/h.
    var unit: String {
        switch self {
        case .battery: "%"
        case .motorTemperature, .controllerTemperature: "°C"
        case .speed: "km/h"
        case .current: "A"
        }
    }

    /// What can be chosen for a threshold: wide enough for a stock Flex and no wider. It runs out below 5%, its
    /// sport gear accelerates to about 25 km/h, and a hard pull draws in the order of 15 A.
    var range: ClosedRange<Double> {
        switch self {
        case .battery: 5...95
        case .motorTemperature: 40...130
        case .controllerTemperature: 40...120
        case .speed: 10...50
        case .current: 2...30
        }
    }

    /// Every reading is whole numbers, so one unit.
    var step: Double { 1 }

    /// The levels worth watching on a Pure Flex, offered as one tap in the editor.
    var presets: [Double] {
        switch self {
        case .battery: [10, 15, 20, 25, 30, 50]
        case .motorTemperature: [60, 70, 80, 90, 100]
        case .controllerTemperature: [55, 65, 70, 80, 90]
        case .speed: [20, 25, 30, 35, 40]
        case .current: [8, 10, 12, 15, 20, 25]
        }
    }

    /// Where a new alert on this reading starts: warm but still fine for the temperatures, faster than the sport
    /// gear accelerates for speed, and a hard pull for current.
    var defaultThreshold: Double {
        switch self {
        case .battery: 20
        case .motorTemperature: 80
        case .controllerTemperature: 70
        case .speed: 30
        case .current: 18
        }
    }

    /// How far the reading must come back before the same rule can fire again, so a value hovering at the threshold is not repeated.
    var rearmMargin: Double {
        switch self {
        case .battery: 5
        case .motorTemperature, .controllerTemperature: 10
        case .speed: 3
        case .current: 2
        }
    }

    func value(in reading: AlertEngine.Reading) -> Double {
        switch self {
        case .battery: Double(reading.batteryPercent)
        case .motorTemperature: Double(reading.motorTemperature)
        case .controllerTemperature: Double(reading.controllerTemperature)
        case .speed: reading.speedKmh
        case .current: reading.current
        }
    }
}

enum AlertDirection: String, Codable, CaseIterable, Identifiable, Sendable {
    case above, below

    var id: String { rawValue }
    var title: String { self == .above ? "Above" : "Below" }
}

/// How serious a rule is, which is the colour of its indicator and banner.
enum AlertSeverity: String, Codable, CaseIterable, Identifiable, Comparable, Sendable {
    case info, warning, critical

    var id: String { rawValue }

    var title: String {
        switch self {
        case .info: "Info"
        case .warning: "Warning"
        case .critical: "Critical"
        }
    }

    var color: Color {
        switch self {
        case .info: .blue
        case .warning: .yellow
        case .critical: .red
        }
    }

    var symbol: String {
        switch self {
        case .info: "info.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .critical: "exclamationmark.octagon.fill"
        }
    }

    private var order: Int { self == .info ? 0 : self == .warning ? 1 : 2 }

    static func < (lhs: AlertSeverity, rhs: AlertSeverity) -> Bool { lhs.order < rhs.order }
}

struct AlertRule: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var name: String
    var metric: AlertMetric
    var direction: AlertDirection
    var threshold: Double
    var severity: AlertSeverity
    /// Also post a notification. The banner in the app and the coloured indicator always follow the rule.
    var notifies: Bool
    var isEnabled: Bool
    /// The rules that come with the app, which can be changed and switched off but not deleted.
    var isBuiltIn: Bool

    init(
        id: UUID = UUID(), name: String, metric: AlertMetric, direction: AlertDirection, threshold: Double,
        severity: AlertSeverity = .warning, notifies: Bool = true, isEnabled: Bool = true, isBuiltIn: Bool = false
    ) {
        self.id = id
        self.name = name
        self.metric = metric
        self.direction = direction
        self.threshold = threshold
        self.severity = severity
        self.notifies = notifies
        self.isEnabled = isEnabled
        self.isBuiltIn = isBuiltIn
    }

    func isMet(by value: Double) -> Bool {
        direction == .above ? value >= threshold : value <= threshold
    }

    /// Whether the reading has come far enough back from the threshold for the rule to fire again.
    func hasReset(at value: Double) -> Bool {
        direction == .above ? value < threshold - metric.rearmMargin : value > threshold + metric.rearmMargin
    }

    /// "Battery at or below 20%", for lists.
    var summary: String {
        let value = threshold.formatted(.number.precision(.fractionLength(0)))
        let unit = metric.unit == "%" ? "%" : " \(metric.unit)"
        return "\(metric.title) \(direction == .above ? "at or above" : "at or below") \(value)\(unit)"
    }

    // MARK: Built in

    static let batteryLowID = UUID(uuidString: "00000000-0000-4000-8000-00000000A001")!
    static let batteryCriticalID = UUID(uuidString: "00000000-0000-4000-8000-00000000A002")!
    static let controllerHotID = UUID(uuidString: "00000000-0000-4000-8000-00000000A003")!
    static let motorHotID = UUID(uuidString: "00000000-0000-4000-8000-00000000A004")!
    static let controllerWarmID = UUID(uuidString: "00000000-0000-4000-8000-00000000A005")!
    static let motorWarmID = UUID(uuidString: "00000000-0000-4000-8000-00000000A006")!

    /// Each reading gets two levels, as a rider wants to know about heat before it matters: the yellow one is a
    /// heads-up in the app only, the red one notifies. The temperatures are where a hub motor and a controller of
    /// this size are warm from a long climb (yellow) and where they are hot enough to pull back power (red).
    static let defaults: [AlertRule] = [
        AlertRule(id: batteryLowID, name: "Battery low", metric: .battery, direction: .below, threshold: 20, severity: .warning, isBuiltIn: true),
        AlertRule(id: batteryCriticalID, name: "Battery critical", metric: .battery, direction: .below, threshold: 10, severity: .critical, isBuiltIn: true),
        AlertRule(id: controllerWarmID, name: "Controller warm", metric: .controllerTemperature, direction: .above, threshold: 70, severity: .warning, notifies: false, isBuiltIn: true),
        AlertRule(id: controllerHotID, name: "Controller hot", metric: .controllerTemperature, direction: .above, threshold: 85, severity: .critical, isBuiltIn: true),
        AlertRule(id: motorWarmID, name: "Motor warm", metric: .motorTemperature, direction: .above, threshold: 80, severity: .warning, notifies: false, isBuiltIn: true),
        AlertRule(id: motorHotID, name: "Motor hot", metric: .motorTemperature, direction: .above, threshold: 100, severity: .critical, isBuiltIn: true),
    ]
}

/// The rules, kept as one JSON string in the settings so a backup carries them and a change is one write.
enum AlertRuleStorage {
    static let key = "alerts.rules"

    static func rules(in defaults: UserDefaults = .standard) -> [AlertRule] {
        if let json = defaults.string(forKey: key), let data = json.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([AlertRule].self, from: data) {
            return decoded
        }
        return migrated(from: defaults)
    }

    static func save(_ rules: [AlertRule], in defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(rules), let json = String(data: data, encoding: .utf8) else { return }
        defaults.set(json, forKey: key)
    }

    /// The built-in rules, with the levels the rider chose before alerts were rules (0 meant off). Those levels
    /// were a single red one per temperature, so they land on the red rule and the yellow one stays as it comes.
    static func migrated(from defaults: UserDefaults) -> [AlertRule] {
        let legacy: [(UUID, String)] = [
            (AlertRule.batteryLowID, "alerts.batteryLow"), (AlertRule.batteryCriticalID, "alerts.batteryCritical"),
            (AlertRule.controllerHotID, "alerts.controllerHot"), (AlertRule.motorHotID, "alerts.motorHot"),
        ]
        return AlertRule.defaults.map { rule in
            guard let key = legacy.first(where: { $0.0 == rule.id })?.1, let stored = defaults.object(forKey: key) as? Int else { return rule }
            var changed = rule
            if stored == 0 { changed.isEnabled = false } else { changed.threshold = Double(stored) }
            return changed
        }
    }
}

/// The rules in memory, so a reading is checked without decoding anything. Edits are written through; a change made
/// elsewhere (a restored backup) is picked up when the stored string differs.
@MainActor
@Observable
final class AlertRuleCenter {
    static let shared = AlertRuleCenter()

    private(set) var rules: [AlertRule]
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var storedJSON: String?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        rules = AlertRuleStorage.rules(in: defaults)
        storedJSON = defaults.string(forKey: AlertRuleStorage.key)
        if storedJSON == nil { persist() }
    }

    func update(_ rule: AlertRule) {
        if let index = rules.firstIndex(where: { $0.id == rule.id }) { rules[index] = rule } else { rules.append(rule) }
        persist()
    }

    func delete(_ rule: AlertRule) {
        guard !rule.isBuiltIn else { return }
        rules.removeAll { $0.id == rule.id }
        persist()
    }

    func resetToDefaults() {
        rules = AlertRule.defaults
        persist()
    }

    /// Reads the settings again if the rules were changed outside this object. Cheap when nothing changed.
    func reloadIfChanged() {
        let current = defaults.string(forKey: AlertRuleStorage.key)
        guard current != storedJSON else { return }
        rules = AlertRuleStorage.rules(in: defaults)
        storedJSON = current
    }

    /// The most serious rule on `metric` that the value meets now, for colouring an indicator. Nil when none is met.
    func severity(for metric: AlertMetric, value: Double) -> AlertSeverity? {
        rules.lazy.filter { $0.isEnabled && $0.metric == metric && $0.isMet(by: value) }.map(\.severity).max()
    }

    /// The temperature limits worth drawing on a chart: enabled rules that fire above a value.
    func limits(for metric: AlertMetric) -> [AlertRule] {
        rules.filter { $0.isEnabled && $0.metric == metric && $0.direction == .above }
    }

    private func persist() {
        AlertRuleStorage.save(rules, in: defaults)
        storedJSON = defaults.string(forKey: AlertRuleStorage.key)
    }
}
