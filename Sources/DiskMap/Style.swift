import SwiftUI

extension Color {
    static let ink = Color(nsColor: Theme.background)
    static let panel = Color(nsColor: Theme.panel)
    static let hairline = Color(nsColor: Theme.hairline)
    static let ember = Color(nsColor: Theme.accent)
    static let caution = Color(.sRGB, red: 1.00, green: 0.78, blue: 0.28, opacity: 1)
}

/// Small caps section label.
struct Overline: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(1.4)
            .foregroundStyle(.white.opacity(0.38))
    }
}

struct Metric: View {
    let value: String
    let caption: String
    var tint: Color = .white

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(tint)
            Overline(text: caption)
        }
    }
}

struct GhostButtonStyle: ButtonStyle {
    var tint: Color = .white
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(tint.opacity(configuration.isPressed ? 0.22 : 0.10))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(tint.opacity(0.18), lineWidth: 1)
            )
            .foregroundStyle(tint.opacity(0.92))
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    var enabled: Bool = true
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(enabled
                          ? LinearGradient(colors: [Color.ember, Color.ember.opacity(0.75)],
                                           startPoint: .top, endPoint: .bottom)
                          : LinearGradient(colors: [Color.white.opacity(0.07), Color.white.opacity(0.07)],
                                           startPoint: .top, endPoint: .bottom))
                    .shadow(color: enabled ? Color.ember.opacity(0.35) : .clear, radius: 12, y: 4)
            )
            .foregroundStyle(enabled ? Color.black.opacity(0.88) : .white.opacity(0.35))
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}
