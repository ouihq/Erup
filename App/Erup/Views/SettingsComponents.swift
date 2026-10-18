import SwiftUI

/// The rounded colour square with a white symbol that iOS Settings puts in front of its rows.
struct SettingsIcon: View {
    let symbol: String
    var tint: Color = .accentColor
    @ScaledMetric(relativeTo: .body) private var box: CGFloat = 30
    @ScaledMetric(relativeTo: .body) private var glyph: CGFloat = 15

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: min(glyph, 22), weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: min(box, 44), height: min(box, 44))
            .background(tint, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// A settings row title with its icon.
struct SettingsLabel: View {
    let title: String
    let symbol: String
    var tint: Color = .accentColor

    var body: some View {
        Label {
            Text(title)
        } icon: {
            SettingsIcon(symbol: symbol, tint: tint)
        }
    }
}

enum SettingsAuth {
    /// Face ID, Touch ID or the passcode, then the action. Used before anything that touches the PIN or deletes data.
    @MainActor
    static func require(_ reason: String, then action: @escaping @MainActor () -> Void) {
        Task {
            if await BiometricGate.authenticate(reason: reason) { action() }
        }
    }
}
