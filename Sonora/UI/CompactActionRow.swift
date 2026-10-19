import SwiftUI

struct CompactActionRow<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 20) { content }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
    }
}

struct CompactActionLabel: View {
    let title: String
    let icon: String
    var prominent = false
    var destructive = false
    @Environment(\.colorScheme) private var scheme
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        let accent = destructive ? Color.red : PlayerTheme(scheme).accent
        Label(title, systemImage: icon)
            .labelStyle(.iconOnly)
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(prominent ? (scheme == .dark ? Color.black : Color.white) : accent)
            .frame(width: 44, height: 44)
            .background(prominent ? accent : accent.opacity(0.12), in: .circle)
            .contentShape(.rect)
            .opacity(isEnabled ? 1 : 0.4)
    }
}
