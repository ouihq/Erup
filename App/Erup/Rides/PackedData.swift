import Foundation

/// Sensor samples and routes are stored as LZFSE-compressed JSON. The compression is lossless: every value is
/// kept exactly as it was recorded. Older rides stored plain JSON; both forms are read, and
/// `StorageMaintenance` rewrites the old ones.
enum PackedData {
    private static let lzfseMagic = Array("bvx".utf8)

    static func isPacked(_ data: Data) -> Bool {
        data.starts(with: lzfseMagic)
    }

    static func pack<T: Encodable>(_ value: T) throws -> Data {
        let json = try JSONEncoder().encode(value)
        return (try? (json as NSData).compressed(using: .lzfse) as Data) ?? json
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let json = isPacked(data) ? try (data as NSData).decompressed(using: .lzfse) as Data : data
        return try JSONDecoder().decode(type, from: json)
    }
}
