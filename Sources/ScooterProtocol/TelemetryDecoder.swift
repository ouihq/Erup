public enum TelemetryEvent: Equatable, Sendable {
    case telemetry1(Telemetry1)
    case telemetry2(Telemetry2)
    case unknown([UInt8])
    case rejected(frame: [UInt8], reason: ProtocolError)
}

public struct TelemetryDecoder: Sendable {
    public static let header: UInt8 = 0xAB
    private static let minimumLength = 5
    private static let maximumLength = 64

    private var buffer: [UInt8] = []
    public private(set) var droppedByteCount = 0
    public private(set) var crcFailureCount = 0

    public init() {}

    public mutating func reset() {
        buffer.removeAll()
    }

    public mutating func feed(_ bytes: [UInt8]) -> [TelemetryEvent] {
        buffer.append(contentsOf: bytes)
        var events: [TelemetryEvent] = []

        while true {
            guard let start = buffer.firstIndex(of: Self.header) else {
                droppedByteCount += buffer.count
                buffer.removeAll()
                break
            }
            if start > 0 {
                droppedByteCount += start
                buffer.removeFirst(start)
            }
            guard buffer.count >= 3 else { break }

            let length = Int(buffer[2])
            guard (Self.minimumLength...Self.maximumLength).contains(length) else {
                dropOne()
                continue
            }
            guard buffer.count >= length else { break }

            let frame = Array(buffer[0..<length])
            guard CRC16.isValid(frame) else {
                crcFailureCount += 1
                dropOne()
                continue
            }
            buffer.removeFirst(length)
            events.append(Self.event(for: frame))
        }
        return events
    }

    private mutating func dropOne() {
        buffer.removeFirst()
        droppedByteCount += 1
    }

    private static func event(for frame: [UInt8]) -> TelemetryEvent {
        do {
            switch (frame[1], frame.count) {
            case (0x00, Telemetry1.length): return .telemetry1(try Telemetry1(parsing: frame))
            case (0x01, Telemetry2.length): return .telemetry2(try Telemetry2(parsing: frame))
            default: return .unknown(frame)
            }
        } catch let error as ProtocolError {
            return .rejected(frame: frame, reason: error)
        } catch {
            return .rejected(frame: frame, reason: .badHeader)
        }
    }
}
