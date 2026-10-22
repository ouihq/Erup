import Foundation

/// Where the scooter's alerts fire, chosen in Settings. A stored 0 means the alert is off; anything else outside the
/// offered choices falls back to the default.
enum AlertSettings {
    struct Option: Identifiable, Hashable {
        let key: String
        let title: String
        let defaultValue: Int
        /// Values offered in the picker; 0 switches the alert off.
        let choices: [Int]
        let unit: String
        var id: String { key }
    }

    static let batteryLow = Option(key: "alerts.batteryLow", title: "Battery low", defaultValue: 20, choices: [0, 15, 20, 25, 30], unit: "%")
    static let batteryCritical = Option(key: "alerts.batteryCritical", title: "Battery critical", defaultValue: 10, choices: [0, 5, 10, 15], unit: "%")
    static let controllerHot = Option(key: "alerts.controllerHot", title: "Controller hot", defaultValue: 70, choices: [0, 60, 65, 70, 75, 80], unit: "°C")
    static let motorHot = Option(key: "alerts.motorHot", title: "Motor hot", defaultValue: 90, choices: [0, 80, 85, 90, 95, 100], unit: "°C")
    static let chargeCompleteKey = "alerts.chargeComplete"

    static func value(_ option: Option, in defaults: UserDefaults = .standard) -> Int {
        guard let stored = defaults.object(forKey: option.key) as? Int, option.choices.contains(stored) else { return option.defaultValue }
        return stored
    }

    static func title(for value: Int, in option: Option) -> String {
        value == 0 ? "Off" : "\(value)\(option.unit == "%" ? "%" : " \(option.unit)")"
    }

    static var limits: AlertEngine.Limits { limits(in: .standard) }

    static func limits(in defaults: UserDefaults) -> AlertEngine.Limits {
        func level(_ option: Option) -> Int? {
            let stored = value(option, in: defaults)
            return stored == 0 ? nil : stored
        }
        return AlertEngine.Limits(
            batteryLow: level(batteryLow), batteryCritical: level(batteryCritical),
            controllerHot: level(controllerHot), motorHot: level(motorHot),
            chargeComplete: defaults.object(forKey: chargeCompleteKey) as? Bool ?? true
        )
    }
}
