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

/// A number picked by dragging, typing or tapping one of the usual values, rather than one tap per unit. Used for
/// alert thresholds, where the span is wide (40 to 130 °C) but the level a rider wants is usually a round number.
struct ValueChooser: View {
    let title: String
    /// Shown after the field: "%", "°C", "km/h".
    let unit: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 1
    /// Offered as capsules under the slider. Values outside the range are left out.
    var presets: [Double] = []

    /// What is in the field while it is being typed in. Nil means the field shows `value`.
    @State private var typed: String?
    @FocusState private var isTyping: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title)
                Spacer(minLength: 8)
                // The field empties when it is tapped, with the value left as its placeholder, so a new number is
                // typed straight in rather than next to the old one.
                TextField(Self.text(value), text: Binding(get: { typed ?? Self.text(value) }, set: { typed = $0 }))
                    .focused($isTyping)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .fontWeight(.semibold)
                    .frame(minWidth: 40)
                    .fixedSize()
                    .accessibilityLabel(title)
                    .onSubmit(commit)
                Text(unit).foregroundStyle(.secondary)
            }
            Slider(value: $value, in: bounds, step: step) {
                Text(title)
            } minimumValueLabel: {
                edge(bounds.lowerBound)
            } maximumValueLabel: {
                edge(bounds.upperBound)
            }
            if !offered.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(offered, id: \.self) { preset in
                            capsule(preset)
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
        }
        .padding(.vertical, 4)
        .onChange(of: value) { typed = nil }
        .onChange(of: isTyping) { _, typing in
            if typing { typed = "" } else { commit() }
        }
        .toolbar {
            if isTyping {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { isTyping = false }
                }
            }
        }
    }

    /// The range, stretched to hold a value that is already outside it — a threshold from an older version of the
    /// app, say — so the slider shows where the value really is instead of pinning it to an end.
    private var bounds: ClosedRange<Double> {
        min(range.lowerBound, value)...max(range.upperBound, value)
    }

    private var offered: [Double] { presets.filter(bounds.contains) }

    private func edge(_ bound: Double) -> some View {
        Text(Self.text(bound))
            .font(.caption2)
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
    }

    private func capsule(_ preset: Double) -> some View {
        let isChosen = abs(preset - value) < step / 2
        return Button {
            isTyping = false
            value = preset
        } label: {
            Text(Self.text(preset))
                .font(.footnote.weight(isChosen ? .semibold : .regular))
                .monospacedDigit()
                .foregroundStyle(isChosen ? Color.accentColor : .secondary)
                .padding(.horizontal, 11)
                .padding(.vertical, 5)
                .background(isChosen ? Color.accentColor.opacity(0.16) : Color.secondary.opacity(0.12), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(Self.text(preset)) \(unit)")
    }

    /// Takes the typed text, rounds it onto the step and keeps it inside the range. Anything unreadable is dropped.
    private func commit() {
        defer { typed = nil }
        let digits = (typed ?? "").filter { $0.isNumber || $0 == "." || $0 == "," }
        guard let entered = Double(digits.replacingOccurrences(of: ",", with: ".")) else { return }
        let stepped = step > 0 ? (entered / step).rounded() * step : entered
        value = min(max(stepped, bounds.lowerBound), bounds.upperBound)
    }

    private static func text(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0)))
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
