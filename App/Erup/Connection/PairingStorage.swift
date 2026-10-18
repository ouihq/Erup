import Foundation

struct PairingStorage: Sendable {
    private static let key = "pairedPeripheralID"

    private var defaults: UserDefaults {
        UserDefaults(suiteName: AppGroup.id) ?? .standard
    }

    var peripheralID: UUID? {
        get { defaults.string(forKey: Self.key).flatMap(UUID.init(uuidString:)) }
        nonmutating set { defaults.set(newValue?.uuidString, forKey: Self.key) }
    }
}
