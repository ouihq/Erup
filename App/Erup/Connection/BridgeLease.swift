import Foundation

/// Tracks which exchange has the scooter in bridge mode. Bridge mode swallows telemetry, so only one
/// exchange may hold it, and only the holder (or a watchdog acting for it) may release it. That keeps a
/// late finisher from closing a newer exchange after iOS suspended the app mid-exchange.
struct BridgeLease: Equatable {
    private(set) var owner: UUID?

    var isActive: Bool { owner != nil }

    /// Returns the new owner, or nil while another exchange still holds the bridge.
    mutating func acquire() -> UUID? {
        guard owner == nil else { return nil }
        let new = UUID()
        owner = new
        return new
    }

    /// With an owner, releases only if it still holds the lease. Without one, releases unconditionally.
    @discardableResult
    mutating func release(owner holder: UUID? = nil) -> Bool {
        guard let current = owner else { return false }
        if let holder, holder != current { return false }
        owner = nil
        return true
    }
}
