import SwiftUI

struct ConnectionBadge: View {
    let state: ConnectionState
    let searchingSince: Date?
    let lastSeen: Date?
    /// In a Form row the status is shown without its own card, so it matches the other rows.
    var plain = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulsing = false

    var body: some View {
        if plain {
            row.padding(.vertical, 2)
        } else {
            row
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .cardBackground()
        }
    }

    private var row: some View {
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(state.tint)
                .frame(width: 10, height: 10)
                .padding(.top, 5)
                .opacity(isBusy && pulsing ? 0.3 : 1)
                .animation(
                    isBusy && !reduceMotion ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true) : .default,
                    value: pulsing
                )
            VStack(alignment: .leading, spacing: 2) {
                Text(state.title).font(.subheadline.weight(.semibold))
                TimelineView(.periodic(from: .now, by: 5)) { context in
                    if let detail = Self.detail(state: state, searchingSince: searchingSince, lastSeen: lastSeen, at: context.date) {
                        Text(detail).font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .onAppear { pulsing = true }
    }

    private var isBusy: Bool {
        switch state {
        case .searching, .connecting, .scanning: true
        default: false
        }
    }

    static func detail(state: ConnectionState, searchingSince: Date?, lastSeen: Date?, at date: Date) -> String? {
        switch state {
        case .bluetoothOff:
            return "Turn on Bluetooth in Control Center or Settings."
        case .unauthorized:
            return "Allow Bluetooth for Erup in Settings."
        case .unsupported:
            return "This device cannot use Bluetooth Low Energy."
        case .searching(let hint):
            var parts: [String] = []
            switch hint {
            case .outOfRange: parts.append("The link dropped. Reconnects automatically when you are close.")
            case .scooterOff: parts.append("The scooter ended the connection, usually because it was turned off.")
            case .silent: parts.append("Connected, but no data is arriving. The scooter may be off or asleep.")
            case .waiting: parts.append("Reconnects automatically when it is on and nearby.")
            }
            if let searchingSince, date.timeIntervalSince(searchingSince) > 30 {
                parts.append("If it is on and close, another phone or the Pure app may be connected to it.")
            }
            if let lastSeen {
                parts.append("Last seen \(lastSeen.formatted(.relative(presentation: .named))).")
            }
            return parts.joined(separator: " ")
        default:
            return nil
        }
    }
}

/// The status of a scooter that is not connected, shown on the Ride tab: what is going on, what happens
/// next, and the one action that helps, all in a single card.
struct ConnectionCard: View {
    let state: ConnectionState
    let searchingSince: Date?
    let lastSeen: Date?

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12)) : AnyLayout(HStackLayout(alignment: .top, spacing: 14))
            layout {
                icon
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.headline)
                    TimelineView(.periodic(from: .now, by: 5)) { context in
                        Text(detail(at: context.date))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            action
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground()
        .accessibilityElement(children: .contain)
    }

    private var isBusy: Bool {
        switch state {
        case .searching(.waiting), .connecting, .scanning: true
        default: false
        }
    }

    private var title: String {
        state == .unpaired ? "Connect your scooter" : state.title
    }

    private func detail(at date: Date) -> String {
        if state == .unpaired {
            return "Pair it to see live speed, battery and controls. Your rides and statistics work without it."
        }
        if state == .connecting { return "Setting up the connection." }
        if state == .scanning { return "Looking for scooters nearby." }
        return ConnectionBadge.detail(state: state, searchingSince: searchingSince, lastSeen: lastSeen, at: date) ?? ""
    }

    private var icon: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(iconTint.opacity(0.16))
            if isBusy {
                ProgressView()
            } else {
                Image(systemName: symbol)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(iconTint)
            }
        }
        .frame(width: 48, height: 48)
        .accessibilityHidden(true)
    }

    private var iconTint: Color {
        switch state {
        case .unpaired: .accentColor
        case .bluetoothOff, .unauthorized, .unsupported: .red
        default: .secondary
        }
    }

    private var symbol: String {
        switch state {
        case .unpaired: "scooter"
        case .bluetoothOff, .unauthorized, .unsupported: "exclamationmark.triangle.fill"
        default: "antenna.radiowaves.left.and.right.slash"
        }
    }

    @ViewBuilder
    private var action: some View {
        if state.needsPairing {
            NavigationLink {
                PairingView()
            } label: {
                Text("Pair a scooter")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        } else if state == .unauthorized {
            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            } label: {
                Text("Open Settings")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        }
    }
}

extension ConnectionState {
    var tint: Color {
        switch self {
        case .connected: .green
        case .searching, .connecting, .scanning: .secondary
        case .bluetoothOff, .unauthorized, .unsupported: .red
        case .unpaired: .gray
        }
    }

    var title: String {
        switch self {
        case .connected: "Connected"
        case .connecting: "Connecting"
        case .scanning: "Scanning"
        case .unpaired: "No scooter paired"
        case .bluetoothOff: "Bluetooth is off"
        case .unauthorized: "Bluetooth access denied"
        case .unsupported: "Bluetooth unavailable"
        case .searching(let hint):
            switch hint {
            case .waiting: "Looking for your scooter"
            case .outOfRange: "Out of range"
            case .scooterOff: "Scooter switched off"
            case .silent: "Scooter not responding"
            }
        }
    }
}
