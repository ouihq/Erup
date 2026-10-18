import Foundation

public enum BridgeFrames {
    public static let slaveAddress: UInt8 = 0x01
    public static let readControllerFunction: UInt8 = 0x07
    public static let readBatteryFunction: UInt8 = 0x08
    public static let readRegistersFunction: UInt8 = 0x03
    public static let writeRegistersFunction: UInt8 = 0x10

    public static let controllerInfoAddresses: [UInt16] = stride(from: 0, to: 80, by: 8).map { UInt16($0) }

    /// The only requests the app can build: read-only, fixed addresses. There is no API for writes
    /// or arbitrary addresses.
    public static let controllerInfoRequests: [[UInt8]] = controllerInfoAddresses.map {
        request(function: readControllerFunction, address: $0, wordCount: 4)
    }

    /// Unconfirmed: assumes the battery read mirrors the controller read with a 16-byte (8-word) payload.
    public static let batteryInfoRequest: [UInt8] = request(function: readBatteryFunction, address: 0, wordCount: 8)

    /// Reads controller register 0 (the control word, with the lock bit) and the four registers after it.
    /// The original iOS app polls exactly this request.
    public static let readControlWordRequest: [UInt8] = request(function: readRegistersFunction, address: 0, wordCount: 5)

    /// Writes the whole 16-bit control word (register 0). Callers must start from a value just read back,
    /// so every other bit is preserved. This is the only write the app can build.
    public static func writeControlWord(_ value: UInt16) -> [UInt8] {
        CRC16.appending(to: [
            slaveAddress, writeRegistersFunction, 0x00, 0x00, 0x00, 0x01, 0x02,
            UInt8(value >> 8), UInt8(value & 0xFF),
        ])
    }

    private static func request(function: UInt8, address: UInt16, wordCount: UInt16) -> [UInt8] {
        CRC16.appending(to: [
            slaveAddress, function,
            UInt8(address >> 8), UInt8(address & 0xFF),
            UInt8(wordCount >> 8), UInt8(wordCount & 0xFF),
        ])
    }
}

public enum BridgeEvent: Equatable, Sendable {
    case data(function: UInt8, address: UInt16, payload: [UInt8])
    case written(address: UInt16, wordCount: UInt16)
    case failure(ProtocolError)
}

public struct BridgeReplyDecoder: Sendable {
    private static let errorFlag: UInt8 = 0x80
    private static let errorFrameLength = 5

    private var buffer: [UInt8] = []
    public private(set) var droppedByteCount = 0

    public init() {}

    public mutating func reset() {
        buffer.removeAll()
    }

    public mutating func feed(_ bytes: [UInt8]) -> [BridgeEvent] {
        buffer.append(contentsOf: bytes)
        var events: [BridgeEvent] = []

        while buffer.count >= 2 {
            guard buffer[0] == BridgeFrames.slaveAddress else {
                dropOne()
                continue
            }
            let function = buffer[1]

            if function >= Self.errorFlag {
                guard buffer.count >= Self.errorFrameLength else { break }
                let frame = Array(buffer[0..<Self.errorFrameLength])
                guard CRC16.isValid(frame) else {
                    dropOne()
                    continue
                }
                buffer.removeFirst(Self.errorFrameLength)
                events.append(.failure(.bridgeError(function: function & ~Self.errorFlag, code: frame[2])))
                continue
            }

            if function == BridgeFrames.writeRegistersFunction {
                guard buffer.count >= 8 else { break }
                let frame = Array(buffer[0..<8])
                guard CRC16.isValid(frame) else {
                    dropOne()
                    continue
                }
                buffer.removeFirst(8)
                events.append(.written(address: frame.uint16(at: 2), wordCount: frame.uint16(at: 4)))
                continue
            }
            guard function == BridgeFrames.readControllerFunction
                || function == BridgeFrames.readBatteryFunction
                || function == BridgeFrames.readRegistersFunction
            else {
                dropOne()
                continue
            }
            guard buffer.count >= 5 else { break }
            let length = 5 + Int(buffer[4]) + 2
            guard buffer.count >= length else { break }

            let frame = Array(buffer[0..<length])
            guard CRC16.isValid(frame) else {
                dropOne()
                continue
            }
            buffer.removeFirst(length)
            events.append(.data(
                function: function,
                address: frame.uint16(at: 2),
                payload: Array(frame[5..<(length - 2)])
            ))
        }
        return events
    }

    private mutating func dropOne() {
        buffer.removeFirst()
        droppedByteCount += 1
    }
}

public struct ControllerInfo: Equatable, Sendable {
    public static let byteCount = 80
    public static let fieldLength = 16

    public let model: String
    public let hardware: String
    public let bootloader: String
    public let firmware: String
    public let uniqueCode: String

    public init(bytes: [UInt8]) throws {
        guard bytes.count == Self.byteCount else {
            throw ProtocolError.invalidControllerInfoLength(bytes.count)
        }
        func field(_ index: Int) -> String {
            let start = index * Self.fieldLength
            let slice = bytes[start..<(start + Self.fieldLength)].prefix { $0 != 0 }
            return String(decoding: slice, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        model = field(0)
        hardware = field(1)
        bootloader = field(2)
        firmware = field(3)
        uniqueCode = field(4)
    }
}
