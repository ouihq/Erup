import Foundation

public enum ATCommand: Equatable, Sendable {
    case rename(suffix: String)
    case verifyPIN(String)
    case changePIN(String)
    case queryPINEnabled
    case setPINEnabled(Bool)
    case queryDevice

    public var expectedReplyKey: String {
        switch self {
        case .rename: "NAME"
        case .verifyPIN: "PWD"
        case .changePIN: "PWDM"
        case .queryPINEnabled, .setPINEnabled: "TYPE"
        case .queryDevice: "DEVICE"
        }
    }

    /// Arguments are wrapped in literal brackets, as the original app sends them (`AT+PWD[123456]`).
    /// The one exception is the PIN-enabled switch, which the original app sends with an unclosed bracket (`AT+TYPE[B`).
    public func encoded() throws -> [UInt8] {
        let (name, argument) = try wire
        var text = "AT+" + name
        if let argument {
            switch self {
            case .setPINEnabled: text += "[" + argument
            default: text += "[" + argument + "]"
            }
        } else {
            text += "?"
        }
        return Array(text.utf8)
    }

    private var wire: (String, String?) {
        get throws {
            switch self {
            case .rename(let suffix):
                guard !suffix.isEmpty, suffix.utf8.count <= 12,
                      suffix.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") })
                else {
                    throw ProtocolError.invalidATArgument("Use 1 to 12 letters, digits, dashes or underscores.")
                }
                return ("NAME", GATT.namePrefix + suffix)
            case .verifyPIN(let pin): return ("PWD", try Self.validated(pin))
            case .changePIN(let pin): return ("PWDM", try Self.validated(pin))
            case .queryPINEnabled: return ("TYPE", nil)
            case .setPINEnabled(let enabled): return ("TYPE", enabled ? "B" : "A")
            case .queryDevice: return ("DEVICE", nil)
            }
        }
    }

    private static func validated(_ pin: String) throws -> String {
        guard pin.count == 6, pin.allSatisfy({ $0.isASCII && $0.isNumber }) else {
            throw ProtocolError.invalidATArgument("The PIN must be exactly 6 digits.")
        }
        return pin
    }
}

public struct ATReply: Equatable, Sendable {
    public enum Status: Sendable, Equatable {
        case ok
        case error
    }

    public let status: Status
    public let key: String
    public let value: String

    public var isOK: Bool { status == .ok }
    private static let knownKeys = [
        "DEVICE", "PWDM", "NAME", "TYPE", "PWD",
    ]

    public static func parse(_ bytes: [UInt8]) throws -> ATReply {
        let text = String(decoding: bytes, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
        let status: Status
        let body: Substring
        if text.hasPrefix("OK+") {
            status = .ok
            body = text.dropFirst(3)
        } else if text.hasPrefix("ERR+") {
            status = .error
            body = text.dropFirst(4)
        } else {
            throw ProtocolError.unrecognizedATReply(text)
        }
        guard let key = knownKeys.first(where: { body.hasPrefix($0) }) else {
            throw ProtocolError.unrecognizedATReply(text)
        }
        var value = body.dropFirst(key.count)
        if value.hasPrefix(":") { value = value.dropFirst() }
        var cleaned = String(value)
        if cleaned.hasPrefix("["), cleaned.hasSuffix("]") { cleaned = String(cleaned.dropFirst().dropLast()) }
        return ATReply(status: status, key: key, value: cleaned.trimmingCharacters(in: .whitespaces))
    }
}
