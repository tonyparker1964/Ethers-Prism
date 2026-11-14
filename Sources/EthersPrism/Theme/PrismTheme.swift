import SwiftUI
import EthersPrismCore

/// Design Option C — Creative Studio: deep charcoal and midnight blue, electric teal accents.
enum PrismTheme {
    static let background = Color(hex: 0x090F17)
    static let sidebar = Color(hex: 0x101C27)
    static let panel = Color(hex: 0x17232E)
    static let teal = Color(hex: 0x00D5C5)
    static let cyan = Color(hex: 0x19E6E0)
    static let text = Color(hex: 0xF5F8FA)
    static let secondaryText = Color(hex: 0x9BAFBD)
    static let border = Color(hex: 0x254451)
    static let selection = Color(hex: 0x123F45)

    static let accentGradient = LinearGradient(colors: [teal, cyan], startPoint: .leading, endPoint: .trailing)
    static let spring = Animation.spring(response: 0.32, dampingFraction: 0.86)
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: opacity)
    }
}

/// A rounded panel with the thin neon border.
struct PrismPanel: ViewModifier {
    var padding: CGFloat = 14
    var glow = false
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(PrismTheme.panel, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(glow ? PrismTheme.teal.opacity(0.55) : PrismTheme.border, lineWidth: 1))
            .shadow(color: glow ? PrismTheme.teal.opacity(0.25) : .clear, radius: 10)
    }
}

extension View {
    func prismPanel(padding: CGFloat = 14, glow: Bool = false) -> some View { modifier(PrismPanel(padding: padding, glow: glow)) }
}

/// The big teal action button (Enhance to 4K, Export…).
struct PrismPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Color(hex: 0x04161A))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(PrismTheme.accentGradient.opacity(enabled ? (configuration.isPressed ? 0.75 : 1) : 0.35),
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .shadow(color: PrismTheme.teal.opacity(enabled ? 0.45 : 0), radius: configuration.isPressed ? 4 : 10)
    }
}

/// A quiet bordered button for the tool bars.
struct PrismToolButtonStyle: ButtonStyle {
    var active = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(active ? PrismTheme.teal : PrismTheme.text)
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(active ? PrismTheme.selection : (configuration.isPressed ? PrismTheme.border : PrismTheme.panel),
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(active ? PrismTheme.teal.opacity(0.6) : PrismTheme.border, lineWidth: 1))
            .contentShape(Rectangle())
    }
}

/// A labelled teal slider with its value, a reset button when changed, and a single undo step per drag.
struct PrismSlider: View {
    let control: StudioControl
    @Binding var value: Double
    /// Called when a drag ends (or reset is pressed), for undo history.
    var onCommit: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(control.label).font(.system(size: 12)).foregroundStyle(PrismTheme.text)
                Spacer()
                if value != control.neutral {
                    Button {
                        withAnimation(PrismTheme.spring) { value = control.neutral }
                        onCommit()
                    } label: { Image(systemName: "arrow.uturn.backward.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(PrismTheme.secondaryText)
                    .help("Reset \(control.label)")
                }
                Text(control.format(value))
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(value == control.neutral ? PrismTheme.secondaryText : PrismTheme.teal)
                    .frame(minWidth: 52, alignment: .trailing)
            }
            Slider(value: $value, in: control.range) { editing in
                if !editing { onCommit() }
            }
            .controlSize(.small)
            .tint(PrismTheme.teal)
        }
        .padding(.vertical, 3)
    }
}

/// Section headings in panels.
struct PrismHeading: View {
    let title: String
    var body: some View {
        Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(PrismTheme.text)
    }
}
