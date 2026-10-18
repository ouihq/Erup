import AppIntents
import SwiftUI
import WidgetKit

struct HeadlightValueProvider: ControlValueProvider {
    var previewValue: Bool { false }

    func currentValue() async throws -> Bool {
        SnapshotStore.load()?.headlightOn ?? false
    }
}

struct LockValueProvider: ControlValueProvider {
    var previewValue: Bool { false }

    func currentValue() async throws -> Bool {
        SnapshotStore.load()?.isLocked ?? false
    }
}

struct HeadlightControl: ControlWidget {
    static let kind = "me.ouihq.erup.control.headlight"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind, provider: HeadlightValueProvider()) { isOn in
            ControlWidgetToggle("Headlight", isOn: isOn, action: SetHeadlightIntent()) { on in
                Label(on ? "On" : "Off", systemImage: "headlight.high.beam.fill")
            }
        }
        .displayName("Scooter headlight")
        .description("Turn the scooter's headlight on or off.")
    }
}

struct LockControl: ControlWidget {
    static let kind = "me.ouihq.erup.control.lock"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind, provider: LockValueProvider()) { isLocked in
            ControlWidgetToggle("Lock", isOn: isLocked, action: SetLockIntent()) { locked in
                Label(locked ? "Locked" : "Unlocked", systemImage: locked ? "lock.fill" : "lock.open.fill")
            }
        }
        .displayName("Scooter lock")
        .description("Lock or unlock the scooter. Only works while standing still.")
    }
}
