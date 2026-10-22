import Foundation
import SwiftUI

/// What a finished ride shows and what is recorded for it. The charts the rider keeps open are stored as a comma
/// separated list of names, so one setting serves every ride and Settings can change the same list the ride page does.
/// Every chart starts folded.
enum RideDisplaySettings {
    /// Charts (speed, power, voltage, battery) and extras (temperature, phone sensors) the rider keeps open.
    static let openKey = "rides.openCharts"
    static let altitudeKey = "rides.recordAltitude"
    static let roughnessKey = "rides.recordRoughness"

    static func isRecordingAltitude(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: altitudeKey) as? Bool ?? true
    }

    static func isRecordingRoughness(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: roughnessKey) as? Bool ?? true
    }

    static func members(of list: String) -> Set<String> {
        Set(list.split(separator: ",").map(String.init))
    }

    static func list(from members: Set<String>) -> String {
        members.sorted().joined(separator: ",")
    }

    /// A switch for one name in a stored list.
    static func binding(_ list: Binding<String>, name: String) -> Binding<Bool> {
        Binding(
            get: { members(of: list.wrappedValue).contains(name) },
            set: { isOn in
                var set = members(of: list.wrappedValue)
                if isOn { set.insert(name) } else { set.remove(name) }
                list.wrappedValue = Self.list(from: set)
            }
        )
    }
}
