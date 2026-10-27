import Foundation
import UserNotifications

@MainActor
final class NotificationService {
    private let center = UNUserNotificationCenter.current()
    private var requestedAuthorization = false
    var onError: (@MainActor (String) -> Void)?

    func requestAuthorizationIfNeeded() async {
        guard !requestedAuthorization else { return }
        requestedAuthorization = true
        do {
            _ = try await center.requestAuthorization(options: [.alert, .sound])
        } catch {
            onError?("Notifications could not be enabled: \(error.localizedDescription)")
        }
    }

    func post(_ alert: AlertEngine.Alert) async {
        let (title, body) = Self.text(for: alert)
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.interruptionLevel = .active
        content.threadIdentifier = "alerts"
        let request = UNNotificationRequest(identifier: "alert.\(title)", content: content, trigger: nil)
        do {
            try await center.add(request)
        } catch {
            onError?("Could not show a notification: \(error.localizedDescription)")
        }
    }

    static func text(for alert: AlertEngine.Alert) -> (String, String) {
        switch alert {
        case .chargeComplete: ("Charging complete", "The scooter battery is full.")
        case .rule(let rule, let value): (rule.name, body(for: rule, value: value))
        }
    }

    private static func body(for rule: AlertRule, value: Double) -> String {
        let shown = value.formatted(.number.precision(.fractionLength(rule.metric == .current ? 1 : 0)))
        switch rule.metric {
        case .battery:
            return rule.severity == .critical ? "\(shown)% left. Find a charger." : "\(shown)% left."
        case .motorTemperature, .controllerTemperature:
            return "\(shown) °C. Ease off or stop to let it cool."
        case .speed: return "\(shown) km/h."
        case .current: return "\(shown) A."
        }
    }
}
