import SonoraCore
import SwiftUI

struct NowPlayingArtwork: View {
    let player: PlaybackController
    let showsLyrics: Bool
    let scrollRequest: Int
    let expandLyrics: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            ArtworkView(image: player.currentDetails?.artwork, cornerRadius: 14)
            if showsLyrics {
                if let lyrics = player.currentDetails?.lyrics, !lyrics.lines.isEmpty {
                    PlayerTheme(scheme).background.opacity(0.72).allowsHitTesting(false)
                    ArtworkLyrics(player: player, lyrics: lyrics, scrollRequest: scrollRequest)
                        .overlay(alignment: .bottom) {
                            LinearGradient(colors: [.clear, PlayerTheme(scheme).background],
                                           startPoint: .top, endPoint: .bottom)
                                .frame(height: 64)
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                        }
                }
                Button(action: expandLyrics) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 18, weight: .medium))
                        .frame(width: 44, height: 44)
                        .background(PlayerTheme(scheme).surface, in: .circle)
                }
                .buttonStyle(.plain)
                .foregroundStyle(PlayerTheme(scheme).accent)
                .accessibilityLabel("Letra")
                .accessibilityHint("Ampliar la letra y editarla")
                .accessibilityIdentifier("expandLyrics")
                .padding(8)
            }
        }
        .clipShape(.rect(cornerRadius: 14))
    }
}

private struct ArtworkLyrics: View {
    let player: PlaybackController
    let lyrics: LyricsDocument
    let scrollRequest: Int
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("lyricsAutoScroll") private var autoScroll = true
    @AppStorage private var offset: Double

    init(player: PlaybackController, lyrics: LyricsDocument, scrollRequest: Int) {
        self.player = player
        self.lyrics = lyrics
        self.scrollRequest = scrollRequest
        _offset = AppStorage(wrappedValue: 0, "lyricsOffset.\(player.current?.id ?? "")")
    }

    private var active: Int? { lyrics.activeLine(at: player.currentTime, offset: offset) }

    var body: some View {
        let activeLine = active
        ScrollViewReader { reader in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(lyrics.lines) { line in
                        Text(line.text.isEmpty ? "♪" : line.text)
                            .font(activeLine == line.id ? .title.bold() : .title3.weight(.semibold))
                            .foregroundStyle(activeLine == line.id ? PlayerTheme(scheme).accent : .primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityValue(activeLine == line.id ? "Línea actual" : "")
                            .accessibilityAddTraits(activeLine == line.id ? .isSelected : [])
                            .id(line.id)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 24)
                .padding(.bottom, 64)
            }
            .accessibilityLabel("Letra de la canción")
            .accessibilityIdentifier("playerLyrics")
            .onChange(of: activeLine, initial: true) { old, new in
                follow(using: reader, animated: old != new)
            }
            .onChange(of: autoScroll) { follow(using: reader, animated: true) }
            // A covered scroll view can discard scroll requests made by the expanded lyrics.
            .onChange(of: scrollRequest) { if lyrics.isTimed { follow(using: reader, animated: true) } }
            .onChange(of: lyrics) {
                if autoScroll { follow(using: reader) }
                else if let first = lyrics.lines.first { reader.scrollTo(first.id, anchor: .top) }
            }
        }
    }

    private func follow(using reader: ScrollViewProxy, animated: Bool = false) {
        guard autoScroll, let target = active ?? lyrics.lines.first?.id else { return }
        withAnimation(animated && !reduceMotion ? .easeInOut(duration: 0.25) : nil) {
            reader.scrollTo(target, anchor: active == nil ? .top : .center)
        }
    }
}
