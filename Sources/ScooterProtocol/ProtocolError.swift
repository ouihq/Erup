import Foundation

public enum ProtocolError: Error, Equatable, Sendable {
    case wrongLength(expected: Int, actual: Int)
    case badHeader
    case badCRC
    case telemetryNotReady
    case refusedWhileMoving(ControlChange, speedKmh: Double)
    case bridgeError(function: UInt8, code: UInt8)
    case invalidControllerInfoLength(Int)
    case unrecognizedATReply(String)
    case invalidATArgument(String)
}

extension ProtocolError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .wrongLength(let expected, let actual):
            "Unexpected frame length \(actual), expected \(expected)."
        case .badHeader:
            "Unrecognized frame header."
        case .badCRC:
            "Frame failed its checksum."
        case .telemetryNotReady:
            "Waiting for the scooter's first status frames."
        case .refusedWhileMoving:
            "Stop the scooter first. This change is only allowed while standing still."
        case .bridgeError(let function, let code):
            "The controller rejected request 0x\(String(function, radix: 16)) with code 0x\(String(code, radix: 16))."
        case .invalidControllerInfoLength(let count):
            "Controller info has \(count) bytes, expected 80."
        case .unrecognizedATReply(let text):
            "Unrecognized reply from the scooter: \(text)"
        case .invalidATArgument(let reason):
            reason
        }
    }
}
