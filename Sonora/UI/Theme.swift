import SwiftUI

enum AppAppearance: String, CaseIterable, Identifiable {
    case noche, papel
    var id: String { rawValue }
    var title: String { switch self { case .noche: "Noche"; case .papel: "Papel" } }
    var colorScheme: ColorScheme { switch self { case .noche: .dark; case .papel: .light } }
}

struct PlayerTheme {
    let isDark: Bool
    init(_ scheme: ColorScheme) { isDark = scheme == .dark }
    var background: Color { isDark ? Color(red: 0.055, green: 0.063, blue: 0.067) : Color(red: 0.975, green: 0.963, blue: 0.937) }
    var surface: Color { isDark ? Color(white: 0.13) : Color(red: 0.935, green: 0.92, blue: 0.89) }
    var accent: Color { isDark ? Color(red: 0.96, green: 0.72, blue: 0.41) : Color(red: 0.66, green: 0.31, blue: 0.21) }
    var heading: Font.Design { isDark ? .default : .serif }
}

struct PlayerGlassGroup<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: 8) { content }
        } else {
            content
        }
    }
}

extension View {
    func playerControlGlass<S: Shape>(in shape: S, prominent: Bool = false, destructive: Bool = false) -> some View {
        modifier(PlayerControlGlass(shape: shape, prominent: prominent, destructive: destructive))
    }

    func playerGlassPanel() -> some View { modifier(PlayerGlassPanel()) }
}

private struct PlayerControlGlass<S: Shape>: ViewModifier {
    let shape: S
    let prominent: Bool
    let destructive: Bool
    @Environment(\.colorScheme) private var scheme
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        let accent = destructive ? Color.red : PlayerTheme(scheme).accent
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular.tint(prominent ? accent : nil).interactive(isEnabled), in: shape)
        } else {
            content.background(prominent ? accent : accent.opacity(0.12), in: shape)
        }
    }
}

private struct PlayerGlassPanel: ViewModifier {
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular, in: .rect(cornerRadius: 26))
        } else {
            content.background(PlayerTheme(scheme).surface, in: .rect(cornerRadius: 14))
        }
    }
}

struct ArtworkView: View {
    let image: UIImage?
    var cornerRadius: CGFloat = 12
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                PlayerTheme(scheme).surface
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Image(systemName: "waveform")
                        .font(.system(size: max(18, proxy.size.width * 0.25), weight: .light))
                        .foregroundStyle(PlayerTheme(scheme).accent)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
        }
        .clipShape(.rect(cornerRadius: cornerRadius))
        .accessibilityHidden(true)
    }
}

func playbackTime(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "0:00" }
    let value = Int(seconds)
    return String(format: "%d:%02d", value / 60, value % 60)
}
