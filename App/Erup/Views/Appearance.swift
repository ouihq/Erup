import SwiftUI

/// One colour per quantity, used everywhere that quantity appears. Controls use the system accent colour.
enum Palette {
    static let speed = Color.orange
    static let power = Color.purple
    static let battery = Color.green
    static let voltage = Color.yellow
    static let current = Color.cyan
    static let temperature = Color.red
}

enum AppearanceSetting: String, CaseIterable, Identifiable {
    static let storageKey = "appearance"

    case system, light, dark

    var id: Self { self }

    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    /// `nil` follows the system setting.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

extension View {
    @ViewBuilder
    func cardBackground(cornerRadius: CGFloat = 20) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26, *) {
            self.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        } else {
            self.background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
        }
        #else
        self.background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
        #endif
    }
}

extension View {
    /// Greys out a live view and says why, for widgets that only make sense with a scooter connected.
    func unavailable(_ isUnavailable: Bool, message: String = "Connect your scooter to see live data") -> some View {
        modifier(UnavailableModifier(isUnavailable: isUnavailable, message: message))
    }
}

private struct UnavailableModifier: ViewModifier {
    let isUnavailable: Bool
    let message: String

    func body(content: Content) -> some View {
        content
            .opacity(isUnavailable ? 0.28 : 1)
            .saturation(isUnavailable ? 0 : 1)
            .blur(radius: isUnavailable ? 1.5 : 0)
            .allowsHitTesting(!isUnavailable)
            .accessibilityHidden(isUnavailable)
            .overlay {
                if isUnavailable {
                    VStack(spacing: 6) {
                        Image(systemName: "antenna.radiowaves.left.and.right.slash")
                            .font(.title3)
                        Text("Unavailable").font(.subheadline.weight(.semibold))
                        Text(message).font(.caption).multilineTextAlignment(.center)
                    }
                    .foregroundStyle(.secondary)
                    .padding(16)
                    .accessibilityElement(children: .combine)
                }
            }
            .motionSafeAnimation(.smooth(duration: 0.25), value: isUnavailable)
    }
}

extension View {
    /// Animates a change unless the person asked for reduced motion.
    func motionSafeAnimation<Value: Equatable>(_ animation: Animation? = .smooth, value: Value) -> some View {
        modifier(MotionSafeAnimation(animation: animation, value: value))
    }
}

private struct MotionSafeAnimation<Value: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let animation: Animation?
    let value: Value

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? nil : animation, value: value)
    }
}

/// Side by side at normal text sizes, stacked when the text is very large, so nothing is cut off.
struct AdaptiveStack<Content: View>: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    var spacing: CGFloat = 8
    var alignment: VerticalAlignment = .center
    @ViewBuilder let content: Content

    var body: some View {
        if typeSize.isAccessibilitySize {
            VStack(spacing: spacing) { content }
        } else {
            HStack(alignment: alignment, spacing: spacing) { content }
        }
    }
}

extension View {
    /// A segmented control, or a menu when the text is so large that segments would be cut off.
    func adaptiveSegmentedStyle() -> some View {
        modifier(AdaptiveSegmentedStyle())
    }
}

private struct AdaptiveSegmentedStyle: ViewModifier {
    @Environment(\.dynamicTypeSize) private var typeSize

    @ViewBuilder
    func body(content: Content) -> some View {
        if typeSize.isAccessibilitySize {
            content.pickerStyle(.menu)
        } else {
            content.pickerStyle(.segmented)
        }
    }
}
