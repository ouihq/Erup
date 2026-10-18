import Foundation

/// Decides what to do when the scooter stops streaming while the link still looks connected. iOS can suspend
/// the app for a while, the keep-alive stops, and the scooter then ends its stream without any disconnect.
/// First restart the stream a few times, then drop the connection so the normal reconnect takes over.
struct StreamStallPolicy: Equatable {
    enum Action: Equatable {
        case none
        case restartSession
        case reconnect
    }

    /// Without a telemetry frame for this long the stream counts as stalled.
    static let quietThreshold: Duration = .seconds(5)
    /// After this long the connection is shown as lost instead of frozen.
    static let silentThreshold: Duration = .seconds(10)
    static let actionSpacing: Duration = .seconds(2)
    static let maximumRestarts = 3

    private(set) var attempts = 0

    mutating func reset() { attempts = 0 }

    func showsAsSilent(silentFor: Duration) -> Bool { silentFor >= Self.silentThreshold }

    mutating func evaluate(silentFor: Duration, sinceLastAction: Duration?) -> Action {
        guard silentFor >= Self.quietThreshold else { return .none }
        if let sinceLastAction, sinceLastAction < Self.actionSpacing { return .none }
        if attempts < Self.maximumRestarts {
            attempts += 1
            return .restartSession
        }
        if attempts == Self.maximumRestarts {
            attempts += 1
            return .reconnect
        }
        return .none
    }
}
