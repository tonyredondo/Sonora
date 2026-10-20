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
    let player: PlaybackController
    let scrollRequest: Int
    @Binding var selection: NowPlayingPage
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            // Keep the full width even when controls or large text limit the height.
            let artworkHeight = max(0, min(geometry.size.width, geometry.size.height - 28))
            carousel.frame(width: geometry.size.width, height: artworkHeight + 28)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var carousel: some View {
        VStack(spacing: 0) {
            ZStack {
                ArtworkView(image: player.currentDetails?.artwork, cornerRadius: 14)
                TabView(selection: $selection) {
                    ForEach(NowPlayingPage.allCases) { page in
                        pageContent(page)
                            .tag(page)
                            .accessibilityHidden(selection != page)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .accessibilityIdentifier("playerCarousel")
            }
            .clipShape(.rect(cornerRadius: 14))
            PlayerPageControl(selection: Binding(get: { selection }, set: { page in
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) { selection = page }
            }))
            .frame(height: 28)
        }
    }

    @ViewBuilder private func pageContent(_ page: NowPlayingPage) -> some View {
        if page == .artwork {
            Color.clear.accessibilityLabel("Portada del álbum")
        } else {
            ZStack(alignment: .bottomTrailing) {
                PlayerTheme(scheme).background.opacity(0.72).allowsHitTesting(false)
                if let lyrics = player.currentDetails?.lyrics, !lyrics.lines.isEmpty {
                    switch page {
                    case .translation:
                        ArtworkTranslation(player: player, lyrics: lyrics, scrollRequest: scrollRequest, isVisible: selection == page)
                    case .meaning:
                        ArtworkMeaning(lyrics: lyrics, store: player.lyricInterpretations)
                    default:
                        ArtworkLyrics(player: player, lyrics: lyrics, scrollRequest: scrollRequest, isVisible: selection == page)
                    }
                } else {
                    ArtworkMessage(message: player.currentDetails == nil ? "Cargando letra…" : "Esta canción todavía no tiene letra.",
                                   busy: player.currentDetails == nil)
                }
                LinearGradient(colors: [.clear, PlayerTheme(scheme).background], startPoint: .top, endPoint: .bottom)
                    .frame(height: 64).allowsHitTesting(false).accessibilityHidden(true)
            }
        }
    }
}

/// SwiftUI's page style places its indicators over the content. A standalone
/// native control keeps the dots below the artwork, with UIKit's scrubbing and
/// VoiceOver behavior and readable colors in both Sonora themes.
private struct PlayerPageControl: UIViewRepresentable {
    @Binding var selection: NowPlayingPage
    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection) }
    func makeUIView(context: Context) -> UIPageControl {
        let control = UIPageControl()
        control.numberOfPages = NowPlayingPage.allCases.count
        control.currentPageIndicatorTintColor = .label
        control.pageIndicatorTintColor = .tertiaryLabel
        control.backgroundStyle = .minimal
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
    let store: LyricInterpretationStore
    @AppStorage("lyricMeaningLanguage") private var language = "es"
    @AppStorage("prepareQueueMeaning") private var automatic = true
    private var key: String { store.key(lyrics, language: language) }
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
                    .padding(.horizontal, 24).padding(.top, 24).padding(.bottom, 72)
                }
                .accessibilityIdentifier("playerMeaning")
            } else {
                ArtworkMessage(message: message, busy: store.statuses[key] == .interpreting)
                    .accessibilityIdentifier("playerMeaningPreparation")
            }
        }
        .task(id: key) { await store.restore(lyrics, language: language) }
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
            .frame(maxWidth: .infinity).padding(24).padding(.bottom, 64)
        }
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
                .padding(.horizontal, 24).padding(.top, 24).padding(.bottom, 72)
            }
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
