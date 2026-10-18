import Foundation
import ScooterProtocol

enum ConnectionState: Equatable, Sendable {
    enum SearchHint: Equatable, Sendable {
        case waiting
        case outOfRange
        case scooterOff
        case silent
    }

    case unsupported
    case bluetoothOff
    case unauthorized
    case unpaired
    case scanning
    case searching(SearchHint)
    case connecting
    case connected

    var isConnected: Bool { self == .connected }

    /// No scooter saved on this phone yet, or the list of nearby scooters is open.
    var needsPairing: Bool {
        switch self {
        case .unpaired, .scanning: true
        default: false
        }
    }
}

struct DiscoveredScooter: Identifiable, Equatable, Sendable {
    let id: UUID
    let name: String
    let rssi: Int
}

struct DeviceInfo: Equatable, Sendable {
    var firmwareRevision: String?
    var systemID: String?
}

enum LinkFailure: Error, Equatable, Sendable {
    case notConnected
    case characteristicMissing(UInt16)
    case writeWithoutResponseUnsupported
    case peripheralUnknown
    case busy
    case timeout
    case commandRejected(String)
    case bluetooth(String)
}

extension LinkFailure: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .notConnected:
            "Not connected to the scooter."
        case .characteristicMissing(let id):
            "The scooter did not expose Bluetooth characteristic \(String(id, radix: 16, uppercase: true))."
        case .writeWithoutResponseUnsupported:
            "The scooter's control characteristic does not accept writes without response."
        case .peripheralUnknown:
            "The saved scooter is no longer known to this iPhone. Pair it again."
        case .busy:
            "The scooter is busy with another request."
        case .timeout:
            "The scooter did not answer in time."
        case .commandRejected(let reply):
            "The scooter rejected the request (\(reply))."
        case .bluetooth(let message):
            message
        }
    }
}

struct ControllerReadout: Equatable, Sendable {
    let info: ControllerInfo
    let batteryBytes: [UInt8]?
    let batteryNote: String?
}

enum LinkEvent: Sendable {
    case state(ConnectionState)
    case telemetry(TelemetryEvent)
    case commandReply([UInt8])
    case deviceInfo(DeviceInfo)
    case discovered(DiscoveredScooter)
    case failure(LinkFailure)
}

protocol ScooterLink: Sendable {
    var events: AsyncStream<LinkEvent> { get }
    func start() async
    func beginPairingScan() async
    func endPairingScan() async
    func pair(with id: UUID) async
    func forget() async
    func write(_ frame: [UInt8]) async throws
    func writeCommand(_ bytes: [UInt8]) async throws
    /// The app is back in the foreground; links that can stall in the background re-check their stream.
    func resumeAfterBackground() async
    func readControllerInfo() async throws -> ControllerReadout
    /// Reads the controller's control word and, when `set` is given, changes only the lock bit and reads it back.
    /// The scooter's regular telemetry does not show the lock bit; this is the only way to know the lock state.
    func lockControlWord(setLockBit set: Bool?) async throws -> UInt16
}

extension ScooterLink {
    func resumeAfterBackground() async {}
}
