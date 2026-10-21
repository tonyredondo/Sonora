import SonoraCore
import SwiftUI
import UIKit

enum NowPlayingPage: Int, CaseIterable, Identifiable {
    case artwork, lyrics, translation, meaning
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .artwork: "Portada"
        case .lyrics: "Letra"
        case .translation: "Traducción"
        case .meaning: "Significado"
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
            VStack(spacing: 0) {
                ArtworkHeaderReflection(image: player.currentDetails?.artwork,
                                        artworkSize: artworkSize, height: topSpace)
                ArtworkView(image: player.currentDetails?.artwork, cornerRadius: 0)
                    .frame(height: artworkSize.height)
            }
            .overlay {
                // Tint the shared artwork, including the status-bar extension,
                // independently of the native pager's inset content bounds.
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
        .overlay(alignment: .top) {
            Rectangle().fill(.ultraThinMaterial)
                .opacity(0.45)
                .mask {
                    // Keep scrolling text recognizable through a light veil,
                    // then dissolve the material below the toolbar.
                    VStack(spacing: 0) {
                        Color.white.frame(height: topSpace)
                        LinearGradient(colors: [.white, .clear],
                                       startPoint: .top, endPoint: .bottom)
                    }
                }
                .frame(height: topSpace + 28)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .overlay(alignment: .bottom) {
            // Native pages may extend below the visible carousel. Fade the
            // composed artwork and text at its actual edge, outside the pager.
            LinearGradient(colors: [.clear, PlayerTheme(scheme).background],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: selection == .artwork ? 32 : 64)
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
                    if let lyrics = player.currentDetails?.lyrics, !lyrics.lines.isEmpty {
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

/// The reflected top edge continues the cover without stretching or cropping it.
/// Only the extension is blurred; the join keeps the original edge's pixels.
private struct ArtworkHeaderReflection: View {
    let image: UIImage?
    let artworkSize: CGSize
    let height: CGFloat
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            if let image {
                reflection(image)
                    .overlay {
                        reflection(image)
                            .blur(radius: 24, opaque: true)
                            .mask {
                                LinearGradient(stops: [.init(color: .white, location: 0),
                                                       .init(color: .white, location: 0.94),
                                                       .init(color: .clear, location: 1)],
                                               startPoint: .top, endPoint: .bottom)
                            }
                    }
            } else {
                PlayerTheme(scheme).surface
            }
            LinearGradient(stops: [.init(color: headerShade, location: 0),
                                   .init(color: headerShade, location: 0.35),
                                   .init(color: .clear, location: 1)],
                           startPoint: .top, endPoint: .bottom)
        }
        .frame(width: artworkSize.width, height: height)
        .clipped()
    }

    private var headerShade: Color {
        PlayerTheme(scheme).background.opacity(scheme == .dark ? 0.6 : 0.8)
    }

    private func reflection(_ image: UIImage) -> some View {
        Image(uiImage: image).resizable().scaledToFill()
            .frame(width: artworkSize.width, height: artworkSize.height)
            .scaleEffect(x: 1, y: -1)
            .frame(width: artworkSize.width, height: height, alignment: .bottom)
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
        _offset = AppStorage(wrappedValue: 0, "lyricsOffset.\(player.current?.id ?? "")")
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
