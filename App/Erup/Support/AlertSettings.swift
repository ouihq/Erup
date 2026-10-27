import Foundation

/// The one alert that is not a rule: it is about an event, not a level.
enum AlertSettings {
    static let chargeCompleteKey = "alerts.chargeComplete"

    static func notifiesChargeComplete(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: chargeCompleteKey) as? Bool ?? true
    }
}
