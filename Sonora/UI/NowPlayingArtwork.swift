import SonoraCore
import SwiftUI
import UIKit

enum NowPlayingPage: Int, CaseIterable, Identifiable {
    case artwork, lyrics, translation, meaning, album
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .artwork: "Portada"
        case .lyrics: "Letra"
        case .translation: "Traducción"
        case .meaning: "Significado"
        case .album: "Álbum"
        }
    }
}

struct NowPlayingArtwork: View {
    static let coordinateSpace = "nowPlayingArtworkLayout"
    let player: PlaybackController
    let scrollRequest: Int
    @Binding var selection: NowPlayingPage
    let topSafeArea: CGFloat
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            // Keep the full width even when controls or large text limit the height.
            let artworkHeight = max(0, min(geometry.size.width, geometry.size.height))
            let topSpace = max(0, geometry.frame(in: .named(Self.coordinateSpace)).minY
                               + (geometry.size.height - artworkHeight) / 2 + topSafeArea)
            carousel(artworkSize: CGSize(width: geometry.size.width, height: artworkHeight), topSpace: topSpace)
                .frame(width: geometry.size.width, height: artworkHeight + topSpace)
                // Extend the scrolling viewport behind the header without
                // changing the cover's size or the controls below it.
                .frame(height: artworkHeight, alignment: .bottom)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func carousel(artworkSize: CGSize, topSpace: CGFloat) -> some View {
        ZStack {
            ArtworkBackdrop(image: player.currentDetails?.artwork, extensionImage: player.currentArtworkExtension,
                            artworkSize: artworkSize, height: topSpace)
            .overlay {
                // Keep one continuous backdrop behind text, including the
                // generated extension, without a separate toolbar veil.
                PlayerTheme(scheme).background.opacity(selection == .artwork ? 0 : 0.72)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: selection)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            TabView(selection: $selection) {
                ForEach(NowPlayingPage.allCases) { page in
                    pageContent(page, topSpace: topSpace)
                        .tag(page)
                        .accessibilityHidden(selection != page)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .accessibilityIdentifier("playerCarousel")
        }
        .clipped()
        .overlay(alignment: .bottom) {
            // Native pages may extend below the visible carousel. Fade the
            // composed artwork and text at its actual edge, outside the pager.
            LinearGradient(colors: [.clear, PlayerTheme(scheme).background],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: selection == .artwork ? 8 : 64)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .overlay(alignment: .bottom) {
            // UIPageControl supplies its own touch animation. An animated
            // binding transaction can leave the native pager on the old page.
            PlayerPageControl(selection: $selection)
            .fixedSize(horizontal: true, vertical: false)
            .frame(height: 44)
            .padding(.bottom, 4)
        }
    }

    @ViewBuilder private func pageContent(_ page: NowPlayingPage, topSpace: CGFloat) -> some View {
        if page == .artwork {
            Color.clear.accessibilityLabel("Portada del álbum")
        } else {
            ZStack(alignment: .bottomTrailing) {
                Group {
                    if page == .album {
                        AlbumContextView(player: player)
                    } else if let lyrics = player.currentDetails?.lyrics, !lyrics.lines.isEmpty {
                        switch page {
                        case .translation:
                            ArtworkTranslation(player: player, lyrics: lyrics, scrollRequest: scrollRequest, isVisible: selection == page)
                        case .meaning:
                            ArtworkMeaning(lyrics: lyrics, context: player.currentInterpretationContext, store: player.lyricInterpretations)
                        default:
                            ArtworkLyrics(player: player, lyrics: lyrics, scrollRequest: scrollRequest, isVisible: selection == page)
                        }
                    } else {
                        ArtworkMessage(message: player.currentDetails == nil ? "Cargando letra…" : "Esta canción todavía no tiene letra.",
                                       busy: player.currentDetails == nil)
                    }
                }
                .safeAreaPadding(.top, topSpace)
            }
        }
    }
}

/// Keep the source cover intact while its upper extension is being prepared.
/// A completed portrait adds the header area without enlarging the source square.
struct ArtworkBackdrop: View {
    let image: UIImage?
    let extensionImage: UIImage?
    let artworkSize: CGSize
    let height: CGFloat

    var body: some View {
        Group {
            if let photo = extensionImage ?? image, photo.size.width > 0, photo.size.height > 0 {
                let viewportHeight = height + artworkSize.height
                let scale = extensionImage != nil
                    ? min(artworkSize.width, viewportHeight) / photo.size.width
                    : min(artworkSize.width / photo.size.width, artworkSize.height / photo.size.height)
                let photoWidth = photo.size.width * scale
                let photoHeight = photo.size.height * scale
                // The source square occupies the bottom of the portrait. Spend
                // any crop on the generated sky, never on the original cover.
                let photoTop = viewportHeight - photoHeight
                Image(uiImage: photo).resizable()
                    .frame(width: photoWidth, height: photoHeight)
                    .offset(y: photoTop)
                    .frame(width: artworkSize.width, height: viewportHeight, alignment: .top)
            } else {
                ArtworkView(image: nil, cornerRadius: 0)
            }
        }
        .frame(width: artworkSize.width, height: height + artworkSize.height)
        .clipped()
    }
}

/// A compact native control preserves UIKit's scrubbing and VoiceOver behavior.
/// Its background keeps the dots readable over both light and dark album art.
private struct PlayerPageControl: UIViewRepresentable {
    @Binding var selection: NowPlayingPage
    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection) }
    func makeUIView(context: Context) -> UIPageControl {
        let control = UIPageControl()
        control.numberOfPages = NowPlayingPage.allCases.count
        control.currentPageIndicatorTintColor = .label
        control.pageIndicatorTintColor = .tertiaryLabel
        control.backgroundStyle = .prominent
        control.accessibilityLabel = "Vistas del reproductor"
        control.accessibilityIdentifier = "playerPages"
        control.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .valueChanged)
        return control
    }
    func updateUIView(_ control: UIPageControl, context: Context) {
        context.coordinator.selection = $selection
        control.currentPage = selection.rawValue
        control.accessibilityValue = "\(selection.title), \(selection.rawValue + 1) de \(NowPlayingPage.allCases.count)"
    }
    final class Coordinator: NSObject {
        var selection: Binding<NowPlayingPage>
        init(selection: Binding<NowPlayingPage>) { self.selection = selection }
        @objc func changed(_ control: UIPageControl) {
            guard let page = NowPlayingPage(rawValue: control.currentPage) else { return }
            selection.wrappedValue = page
        }
    }
}

private struct ArtworkTranslation: View {
    let player: PlaybackController
    let lyrics: LyricsDocument
    let scrollRequest: Int
    let isVisible: Bool
    @AppStorage("lyricTranslationSource") private var source = "auto"
    @AppStorage("lyricTranslationTarget") private var target = "es"
    @AppStorage("prepareQueueTranslation") private var automatic = true
    private var key: String { LyricUnderstanding.translationKey(lyrics, source: source, target: target) }

    var body: some View {
        let key = key
        let translation = player.lyricTranslations.results[key]
        let status = player.lyricTranslations.statuses[key]
        ArtworkLyrics(player: player, lyrics: lyrics, scrollRequest: scrollRequest, isVisible: isVisible,
                      translation: translation, translated: true,
                      preparation: translation == nil ? player.lyricTranslations.message(for: key) ?? (automatic ? "Traducción pendiente…" : "La traducción automática está desactivada.") : nil,
                      preparing: status?.busy == true)
        // Cache restoration only. Page navigation must never enqueue generation.
        .task(id: key) { await player.lyricTranslations.restore(lyrics, source: source, target: target) }
    }
}

private struct ArtworkMeaning: View {
    let lyrics: LyricsDocument
    let context: LyricsInterpretationContext
    let store: LyricInterpretationStore
    @AppStorage("lyricMeaningLanguage") private var language = "es"
    @AppStorage("prepareQueueMeaning") private var automatic = true
    private var key: String { store.key(lyrics, language: language, context: context) }
    private var message: String {
        if case .failed(let issue) = store.statuses[key] { return issue }
        if store.statuses[key] == .interpreting { return "Preparando significado…" }
        if let issue = store.automaticIssue { return issue }
        if store.waitingForConnection { return "Pendiente de conexión con el servidor." }
        return automatic ? "Significado en cola…" : "El significado automático está desactivado."
    }
    var body: some View {
        let key = key
        Group {
            if let result = store.results[key] {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Sobre la canción").font(.headline).accessibilityAddTraits(.isHeader)
                            .accessibilityIdentifier("playerMeaningTitle")
                        Text(result.explanation).font(.body)
                            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                            .accessibilityIdentifier("playerMeaningText")
                        Text("Interpretación de IA").font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 24).padding(.top, 24)
                }
                .contentMargins(.bottom, 104, for: .scrollContent)
                .accessibilityIdentifier("playerMeaning")
            } else {
                ArtworkMessage(message: message, busy: store.statuses[key] == .interpreting)
                    .accessibilityIdentifier("playerMeaningPreparation")
            }
        }
        .task(id: key) { await store.restore(lyrics, language: language, context: context) }
    }
}

private struct ArtworkMessage: View {
    let message: String
    let busy: Bool
    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                if busy { ProgressView() }
                Text(message).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity).padding(24)
        }
        .contentMargins(.bottom, 104, for: .scrollContent)
    }
}

private struct ArtworkLyrics: View {
    let player: PlaybackController
    let lyrics: LyricsDocument
    let scrollRequest: Int
    let isVisible: Bool
    var translation: LyricTranslation?
    var translated = false
    var preparation: String?
    var preparing = false
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("lyricsAutoScroll") private var autoScroll = true
    @AppStorage private var offset: Double

    init(player: PlaybackController, lyrics: LyricsDocument, scrollRequest: Int, isVisible: Bool,
         translation: LyricTranslation? = nil, translated: Bool = false, preparation: String? = nil, preparing: Bool = false) {
        self.player = player; self.lyrics = lyrics; self.scrollRequest = scrollRequest; self.isVisible = isVisible
        self.translation = translation; self.translated = translated; self.preparation = preparation; self.preparing = preparing
        _offset = AppStorage(wrappedValue: 0, player.lyricsOffsetKey(for: player.current))
    }
    private var active: Int? { lyrics.activeLine(at: player.currentTime, offset: offset) }

    var body: some View {
        let activeLine = active
        ScrollViewReader { reader in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: lyrics.isTimed ? 2 : 18) {
                    ForEach(lyrics.lines) { line in
                        let text = VStack(alignment: .leading, spacing: 6) {
                            Text(line.text.isEmpty ? "♪" : line.text)
                                .font(activeLine == line.id ? .title.bold() : .title3.weight(.semibold))
                                .foregroundStyle(activeLine == line.id ? PlayerTheme(scheme).accent : .primary)
                                .fixedSize(horizontal: false, vertical: true)
                            if let text = translation?.lines[line.id] {
                                Text(text).font(.body).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        Group {
                            if let time = line.time {
                                Button { player.seek(to: max(0, time + offset)) } label: {
                                    text.padding(.vertical, 8).frame(minHeight: 44).contentShape(.rect)
                                }
                                .buttonStyle(.plain)
                                .accessibilityHint("Saltar a esta parte de la canción")
                                .accessibilityIdentifier("\(translated ? "translatedLyricLine" : "artworkLyricLine")\(line.id)")
                            } else {
                                text
                            }
                        }
                        .accessibilityValue(activeLine == line.id ? "Línea actual" : "")
                        .accessibilityAddTraits(activeLine == line.id ? .isSelected : [])
                        .id(line.id)
                    }
                }
                .padding(.horizontal, 24).padding(.top, 24)
            }
            // The native pager's scroll bounds can extend below its visible
            // clip. Leave clearance for that inset and the overlaid dots.
            .contentMargins(.bottom, 104, for: .scrollContent)
            .accessibilityLabel(translated ? "Letra traducida" : "Letra de la canción")
            .accessibilityIdentifier(translated ? "playerTranslatedLyrics" : "playerLyrics")
            .safeAreaInset(edge: .top, spacing: 0) {
                if let preparation {
                    HStack(spacing: 8) {
                        if preparing { ProgressView() }
                        Text(preparation).font(.caption).fixedSize(horizontal: false, vertical: true)
                    }
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 24).padding(.top, 12)
                    .accessibilityIdentifier("playerTranslationPreparation")
                } else if let attribution = lyrics.attribution {
                    Text(attribution).font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 24).padding(.top, 16)
                        .accessibilityIdentifier("playerLyricsAttribution")
                }
            }
            .onChange(of: activeLine, initial: true) { old, new in follow(using: reader, animated: old != new) }
            .onChange(of: autoScroll) { follow(using: reader, animated: true) }
            .onChange(of: isVisible) { if isVisible { follow(using: reader) } }
            .onChange(of: translation) { follow(using: reader) }
            .onChange(of: scrollRequest) { if lyrics.isTimed { follow(using: reader, animated: true) } }
            .onChange(of: lyrics) {
                if autoScroll { follow(using: reader) }
                else if let first = lyrics.lines.first { reader.scrollTo(first.id, anchor: .top) }
            }
        }
    }
    private func follow(using reader: ScrollViewProxy, animated: Bool = false) {
        guard isVisible, autoScroll, let target = active ?? lyrics.lines.first?.id else { return }
        withAnimation(animated && !reduceMotion ? .easeInOut(duration: 0.25) : nil) {
            reader.scrollTo(target, anchor: active == nil ? .top : .center)
        }
    }
}
