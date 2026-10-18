extension Array where Element == UInt8 {
    func uint16(at index: Int) -> UInt16 {
        UInt16(self[index]) << 8 | UInt16(self[index + 1])
    }

    func int16(at index: Int) -> Int16 {
        Int16(bitPattern: uint16(at: index))
    }

    func uint24(at index: Int) -> UInt32 {
        UInt32(self[index]) << 16 | UInt32(self[index + 1]) << 8 | UInt32(self[index + 2])
    }
}
