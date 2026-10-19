import Foundation

/// Keeps keep-alives off the wire for a moment after a bridge exchange is closed.
///
/// Real-scooter tests (a Mac script, 36 exchanges plus a five minute soak) showed that a keep-alive sent right after
/// the leave-bridge frame stops the telemetry stream for good: 8 of 8 lock-state reads in the soak, and a keep-alive
/// burst never revived it, only a reconnect (which beeps) did. Staying silent for 250 ms or 500 ms after the leave
/// frame resumed the stream 12 of 12 times.
struct KeepAliveGate: Equatable {
    static let holdAfterLeavingBridge: Duration = .milliseconds(400)

    private var heldUntil: ContinuousClock.Instant?

    mutating func holdAfterBridge(now: ContinuousClock.Instant) {
        heldUntil = now + Self.holdAfterLeavingBridge
    }

    mutating func reset() { heldUntil = nil }

    func allows(at now: ContinuousClock.Instant) -> Bool {
        guard let heldUntil else { return true }
        return now >= heldUntil
    }
}

/// Decides what to do when the scooter stops streaming while the link still looks connected.
///
/// A diagnostic log from a real scooter showed three stalls. Sending the start frame again on its own never revived
/// the stream, while dropping the link and reconnecting brought frames back within about one second every time.
/// A reconnect makes the scooter beep, so a quieter step comes first. Experiments on a Mac against the real scooter
/// showed that a short burst of keep-alives revives a stalled stream in 0.1 to 0.5 s without a reconnect (3 of 3
/// times). If the burst does not bring frames back, reconnect.
/// A healthy stream never had a gap of even two seconds, so four seconds of silence is a safe signal.
struct StreamStallPolicy: Equatable {
    enum Action: Equatable {
        case none
        /// Send a short burst of keep-alives. The link stays up, so no beep.
        case sendKeepAlives
        /// Drop the link and connect again. The scooter beeps when a connection is made.
        case reconnect
    }

    /// Without a telemetry frame for this long the stream counts as stalled.
    static let quietThreshold: Duration = .seconds(4)
    /// After a bridge exchange the stream is expected back almost at once. In the log it either resumed within a
    /// second or never did, so waiting longer only prolongs "scooter not responding".
    static let afterBridgeThreshold: Duration = .seconds(2)

    private var stage = 0

    /// True once recovery has started and frames have not come back yet.
    var isRecovering: Bool { stage > 0 }

    /// Call when frames arrive again or a new session starts.
    mutating func reset() { stage = 0 }

    private static func threshold(afterBridge: Bool) -> Duration {
        afterBridge ? afterBridgeThreshold : quietThreshold
    }

    func showsAsSilent(silentFor: Duration, afterBridge: Bool = false) -> Bool {
        silentFor >= Self.threshold(afterBridge: afterBridge)
    }

    /// First the quiet step, then (unless the rider chose never to) at most one reconnect per stall. How long the quiet
    /// step gets before the reconnect is the rider's choice.
    mutating func evaluate(silentFor: Duration, afterBridge: Bool = false, recovery: StallRecovery = .quick) -> Action {
        let threshold = Self.threshold(afterBridge: afterBridge)
        switch stage {
        case 0:
            guard silentFor >= threshold else { return .none }
            stage = 1
            return .sendKeepAlives
        case 1:
            guard let grace = recovery.reconnectGrace, silentFor >= threshold + grace else { return .none }
            stage = 2
            return .reconnect
        default:
            return .none
        }
    }
}
