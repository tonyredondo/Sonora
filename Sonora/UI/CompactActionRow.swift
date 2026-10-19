import SwiftUI

enum CompactActionLayout {
    case icons, inline
}

private struct CompactActionLayoutKey: EnvironmentKey {
    static let defaultValue = CompactActionLayout.icons
}

private extension EnvironmentValues {
    var compactActionLayout: CompactActionLayout {
        get { self[CompactActionLayoutKey.self] }
        set { self[CompactActionLayoutKey.self] = newValue }
    }
}

struct CompactActionRow<Content: View>: View {
    var layout: CompactActionLayout = .icons
    @ViewBuilder let content: Content

    var body: some View {
        PlayerGlassGroup { row }
    }

    private var row: some View {
        ViewThatFits(in: .horizontal) {
            actions.fixedSize(horizontal: true, vertical: false)
            if layout == .inline {
                VStack(alignment: .leading, spacing: 8) { content }
            } else {
                ScrollView(.horizontal) { actions }
                    .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .buttonStyle(.plain)
        .environment(\.compactActionLayout, layout)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: layout == .inline ? .leading : .center)
        .padding(.vertical, layout == .inline ? 0 : 4)
    }

    private var actions: some View { HStack(alignment: .top, spacing: 8) { content } }
}

/// Keep a small set of actions beside its context, moving below it when text needs room.
struct CompactActionHeader<Title: View, Actions: View>: View {
    @ViewBuilder let title: Title
    @ViewBuilder let actions: Actions

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                title.fixedSize(horizontal: true, vertical: true)
                Spacer(minLength: 12)
                actions.fixedSize(horizontal: true, vertical: true)
            }
            VStack(alignment: .leading, spacing: 8) {
                title
                actions
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension View {
    func compactContentSpacing() -> some View {
        listSectionSpacing(16)
            .contentMargins(.top, 8, for: .scrollContent)
    }

    /// Standalone action bars do not need a second, grouped background.
    func compactActionListRow() -> some View {
        listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
            .listSectionSpacing(8)
    }
}

struct CompactActionLabel: View {
    let title: String
    let icon: String
    var caption: String? = nil
    var prominent = false
    var destructive = false
    @ScaledMetric(relativeTo: .caption2) private var actionWidth = 60
    @Environment(\.colorScheme) private var scheme
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.compactActionLayout) private var layout

    var body: some View {
        let accent = destructive ? Color.red : PlayerTheme(scheme).accent
        Group {
            if layout == .inline {
                Label(caption ?? title, systemImage: icon)
                    .labelStyle(.titleAndIcon)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(prominent ? (scheme == .dark ? Color.black : Color.white) : accent)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .frame(minWidth: 44, minHeight: 44)
                    .playerControlGlass(in: Capsule(), prominent: prominent, destructive: destructive)
            } else {
                iconLabel(accent: accent)
            }
        }
        .contentShape(.rect)
        .opacity(isEnabled ? 1 : 0.4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
    }

    private func iconLabel(accent: Color) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(prominent ? (scheme == .dark ? Color.black : Color.white) : accent)
                .frame(width: 44, height: 44)
                .playerControlGlass(in: Circle(), prominent: prominent, destructive: destructive)
            Text(caption ?? title)
                .font(.caption2.weight(.medium))
                .foregroundStyle(destructive ? Color.red : .primary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .frame(minWidth: actionWidth)
    }
}

/// A native menu promotes glass inside its label to the full label bounds.
/// Keep the visible label outside it while the transparent menu covers both icon and caption.
struct CompactActionMenu<Content: View>: View {
    let title: String
    let icon: String
    var caption: String? = nil
    @ViewBuilder let content: Content

    var body: some View {
        CompactActionLabel(title: title, icon: icon, caption: caption)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .overlay {
                Menu { content } label: {
                    Color.clear.contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityHidden(false)
                .accessibilityLabel(title)
            }
    }
}
