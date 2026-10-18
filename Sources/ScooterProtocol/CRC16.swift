public enum CRC16 {
    private static let table: [UInt16] = (0..<256).map { index in
        var crc = UInt16(index)
        for _ in 0..<8 {
            crc = crc & 1 == 1 ? (crc >> 1) ^ 0xA001 : crc >> 1
        }
        return crc
    }

    public static func modbus<S: Sequence>(_ bytes: S) -> UInt16 where S.Element == UInt8 {
        var crc: UInt16 = 0xFFFF
        for byte in bytes {
            crc = (crc >> 8) ^ table[Int((crc ^ UInt16(byte)) & 0xFF)]
        }
        return crc
    }

    public static func appending(to payload: [UInt8]) -> [UInt8] {
        let crc = modbus(payload)
        return payload + [UInt8(crc & 0xFF), UInt8(crc >> 8)]
    }

    public static func isValid(_ frame: [UInt8]) -> Bool {
        guard frame.count >= 3 else { return false }
        let body = frame.dropLast(2)
        let expected = modbus(body)
        return frame[frame.count - 2] == UInt8(expected & 0xFF)
            && frame[frame.count - 1] == UInt8(expected >> 8)
    }
}
