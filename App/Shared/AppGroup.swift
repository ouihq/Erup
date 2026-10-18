import Foundation

enum AppGroup {
    static let defaultID = "group.me.ouihq.erup"

    /// Sideloading tools re-sign the app with a different group (they append the team ID). Ask the app itself
    /// which groups it really has: AltStore and SideStore list them in Info.plist, and every signed app carries
    /// them in its provisioning profile. A normal Xcode install uses the default.
    static let id: String = {
        let injected = Bundle.main.object(forInfoDictionaryKey: "ALTAppGroups") as? [String] ?? []
        let candidates = injected + provisionedGroups()
        return candidates.first { $0.hasPrefix(defaultID) } ?? candidates.first ?? defaultID
    }()

    private static func provisionedGroups() -> [String] {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8)),
              start.lowerBound < end.upperBound,
              let plist = try? PropertyListSerialization.propertyList(
                  from: data.subdata(in: start.lowerBound..<end.upperBound), format: nil
              ) as? [String: Any],
              let entitlements = plist["Entitlements"] as? [String: Any]
        else { return [] }
        return entitlements["com.apple.security.application-groups"] as? [String] ?? []
    }
}
