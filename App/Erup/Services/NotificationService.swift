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
        let request = UNNotificationRequest(identifier: "alert.\(title)", content: content, trigger: nil)
        do {
            try await center.add(request)
        } catch {
            onError?("Could not show a notification: \(error.localizedDescription)")
        }
    }

    static func text(for alert: AlertEngine.Alert) -> (String, String) {
        switch alert {
        case .batteryLow(let percent): ("Scooter battery low", "\(percent)% left.")
        case .batteryCritical(let percent): ("Scooter battery critical", "\(percent)% left. Find a charger.")
        case .controllerHot(let degrees): ("Controller is hot", "\(degrees) °C. Ease off or stop to let it cool.")
        case .motorHot(let degrees): ("Motor is hot", "\(degrees) °C. Ease off or stop to let it cool.")
        case .chargeComplete: ("Charging complete", "The scooter battery is full.")
        }
    }
}
