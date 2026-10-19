import SonoraCore
import SwiftUI

struct LyricsView: View {
    let player: PlaybackController
    var track: AudioTrack? = nil
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var textSize
    @AppStorage("lyricsAutoScroll") private var autoScroll = true
    @State private var showUnderstanding = false
    @State private var translation: LyricTranslation?
    @State private var translationSourceKey = ""
    @AppStorage("lyricTranslationSource") private var translationSource = "auto"
    @AppStorage("lyricTranslationTarget") private var translationTarget = "es"
    @AppStorage("showLyricTranslation") private var showTranslation = true
    @State private var offset: Double = 0
    @State private var loadedLyrics: LyricsDocument?
    @State private var loadedTrackID: String?
    @State private var title = ""
    @State private var artist = ""
    @State private var issue: String?
    @State private var refresh = UUID()
    @State private var adjusting = false
    @State private var editAfterTiming = false
    private struct EditorRequest: Identifiable {
        let track: AudioTrack
        let synchronize: Bool
        var id: String { track.id }
    }
    @State private var editor: EditorRequest?
    private struct RepairRequest: Hashable {
        let track: AudioTrack
        static func == (lhs: Self, rhs: Self) -> Bool { lhs.track.id == rhs.track.id }
        func hash(into hasher: inout Hasher) { hasher.combine(track.id) }
    }
    @State private var repair: RepairRequest?
    private var selectedTrack: AudioTrack? { track ?? player.current }
    private var isCurrent: Bool { selectedTrack?.id == player.current?.id }
    private var lyrics: LyricsDocument {
        if loadedTrackID == selectedTrack?.id, let loadedLyrics { return loadedLyrics }
        return isCurrent ? player.currentDetails?.lyrics ?? LyricsDocument(text: "") : LyricsDocument(text: "")
    }
    private var active: Int? { isCurrent ? lyrics.activeLine(at: player.currentTime, offset: offset) : nil }

    private var translationKey: String { LyricUnderstanding.translationKey(lyrics, source: translationSource, target: translationTarget) }
    private var visibleTranslation: LyricTranslation? { showTranslation && translationSourceKey == translationKey ? translation : nil }

    private var trackHeading: some View {
        HStack(spacing: 12) {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.isEmpty ? selectedTrack?.displayName ?? "Letra" : title).font(.headline).lineLimit(2)
            if !artist.isEmpty { Text(artist).font(.subheadline).foregroundStyle(.secondary) }
        }
        Spacer(minLength: 0)
        if !lyrics.lines.isEmpty {
            Button { showUnderstanding = true } label: { CompactActionLabel(title: "Comprender letra", icon: "character.book.closed", caption: "Comprender") }
                .buttonStyle(.plain).accessibilityIdentifier("understandLyrics")
        }
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if lyrics.lines.isEmpty {
                        CompactActionHeader {
                            trackHeading
                        } actions: {
                            CompactActionRow(layout: .inline) {
                                Button { edit() } label: { CompactActionLabel(title: "Editar texto", icon: "pencil", caption: "Editar") }
                                    .accessibilityIdentifier("editLyricsText")
                            }.disabled(selectedTrack == nil)
                        }
                    } else {
                        trackHeading
                        CompactActionRow {
                            Button { edit() } label: { CompactActionLabel(title: "Editar texto", icon: "pencil", caption: "Editar") }
                                .accessibilityIdentifier("editLyricsText")
                            Button { openRepair() } label: { CompactActionLabel(title: "Reparar y completar", icon: "text.badge.checkmark", caption: "Reparar") }
                                .accessibilityIdentifier("repairLyrics")
                            Button { edit(synchronize: true) } label: {
                                CompactActionLabel(title: lyrics.isTimed ? "Sincronizar de nuevo" : "Sincronizar letra", icon: "waveform", caption: "Sincronizar")
                            }.accessibilityIdentifier("synchronizeUntimedLyrics")
                            if lyrics.isTimed {
                                if isCurrent {
                                    Toggle(isOn: $autoScroll) {
                                        CompactActionLabel(title: "Seguir canción", icon: autoScroll ? "arrow.down.square.fill" : "arrow.down.square", caption: "Seguir", prominent: autoScroll)
                                    }.toggleStyle(.button).accessibilityIdentifier("followLyrics")
                                }
                                Button { adjusting = true } label: { CompactActionLabel(title: "Ajustar tiempos", icon: "clock", caption: "Tiempos") }
                                    .accessibilityIdentifier("adjustLyricsTiming")
                            }
                        }.disabled(selectedTrack == nil)
                    }
                }.padding(.horizontal).padding(.vertical, 12)
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(maxHeight: textSize.isAccessibilitySize ? 300 : nil)
                .fixedSize(horizontal: false, vertical: !textSize.isAccessibilitySize)
                .contentShape(.rect).clipped()
                .accessibilityIdentifier("lyricsTools")
                Divider()
                if let issue {
                    ContentUnavailableView("No se pudo leer la letra", systemImage: "exclamationmark.circle", description: Text(issue))
                    Button("Reintentar") { refresh = UUID() }.padding()
                } else if loadedTrackID != selectedTrack?.id && lyrics.lines.isEmpty {
                    ProgressView("Leyendo letra…").frame(maxHeight: .infinity)
                } else if lyrics.lines.isEmpty {
                    ContentUnavailableView {
                        Label("Sin letra", systemImage: "quote.bubble")
                    } description: {
                        Text("Busca una letra o añade el texto. Si no la encontramos, podrás transcribir el audio con IA.")
                    } actions: {
                        Button("Buscar letra") { edit(synchronize: true) }.accessibilityIdentifier("findMissingLyrics")
                        Button("Añadir letra") { edit() }
                    }
                } else {
                    ScrollViewReader { reader in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 22) {
                                ForEach(lyrics.lines) { line in
                                    if let time = line.time, isCurrent {
                                        Button { player.seek(to: max(0, time + offset)) } label: {
                                            VStack(alignment: .leading, spacing: 6) {
                                            Text(line.text.isEmpty ? "♪" : line.text)
                                                .font(active == line.id ? .title.bold() : .title2.weight(.medium))
                                                .foregroundStyle(active == line.id ? PlayerTheme(scheme).accent : .primary)
                                                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                            if let translated = visibleTranslation?.lines[line.id] { Text(translated).font(.body).foregroundStyle(.secondary) }
                                            }
                                        }.buttonStyle(.plain).id(line.id).accessibilityIdentifier("lyricLine\(line.id)")
                                            .accessibilityValue(active == line.id ? "Línea actual" : playbackTime(time))
                                    } else {
                                        VStack(alignment: .leading, spacing: 6) {
                                            Text(line.text).font(.title3).textSelection(.enabled)
                                            if let translated = visibleTranslation?.lines[line.id] { Text(translated).font(.body).foregroundStyle(.secondary).textSelection(.enabled) }
                                        }
                                    }
                                }
                            }.padding(24)
                        }
                        .contentShape(.rect).clipped()
                        .accessibilityIdentifier("lyricsReader")
                        .onChange(of: active, initial: true) { scroll(reader) }
                        .onChange(of: autoScroll) { scroll(reader) }
                    }
                    if visibleTranslation != nil { Text("Traducción automática · Apple").font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("lyricsTranslationSource") }
                    if let attribution = lyrics.attribution {
                        Text(attribution).font(.caption).foregroundStyle(.secondary).padding(8).accessibilityIdentifier("lyricsSource")
                    } else if isCurrent, let source = player.currentDetails?.lyricsSource {
                        Text(source).font(.caption).foregroundStyle(.secondary).padding(8).accessibilityIdentifier("lyricsSource")
                    }
                }
            }
            .background(PlayerTheme(scheme).background)
            .navigationTitle("Letra").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Listo") { dismiss() } } }
            .task(id: "\(selectedTrack?.id ?? "")-\(refresh)") { await load() }
            .task(id: translationKey) {
                let key = translationKey
                translation = nil
                if let value = try? await MusicToolsCache.shared.read(LyricTranslation.self, key: key),
                   let validated = try? LyricTranslation(lines: value.lines, document: lyrics), !Task.isCancelled {
                    translation = validated; translationSourceKey = key
                }
            }
            .sheet(isPresented: $showUnderstanding) {
                let sourceKey = LyricUnderstanding.sourceKey(lyrics)
                LyricUnderstandingView(document: lyrics, translation: visibleTranslation) { value in
                    guard sourceKey == LyricUnderstanding.sourceKey(lyrics) else { return }
                    translation = value; translationSourceKey = translationKey; showTranslation = value != nil
                }.id(sourceKey)
            }
            .onChange(of: offset) {
                if let id = selectedTrack?.id, loadedTrackID == id { UserDefaults.standard.set(offset, forKey: "lyricsOffset.\(id)") }
            }
            .onChange(of: repair) { if repair == nil { refresh = UUID() } }
            .sheet(item: $editor, onDismiss: { refresh = UUID() }) {
                MetadataEditorView(player: player, track: $0.track, synchronizeLyricsOnOpen: $0.synchronize, lyricsOnly: true)
            }
            .sheet(isPresented: $adjusting, onDismiss: {
                if editAfterTiming { editAfterTiming = false; edit() }
            }) {
                NavigationStack {
                    Form {
                        Section("Toda la letra") {
                            Text("Desplazamiento: \(offset, specifier: "%+.1f") s").monospacedDigit()
                            MediaSlider(value: $offset, range: -5...5, tint: PlayerTheme(scheme).accent, label: "Ajuste de sincronización")
                                .frame(height: 44).accessibilityIdentifier("lyricsOffset")
                            Button("Restablecer ajuste") { offset = 0 }
                            Text("Un valor positivo retrasa las frases; uno negativo las adelanta. El ajuste se guarda automáticamente para esta canción.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        Section("Frases individuales") {
                            Button("Editar tiempos por frase") { editAfterTiming = true; adjusting = false }
                        }
                    }
                    .navigationTitle("Ajustar tiempos").navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Listo") { adjusting = false } } }
                }
            }
            .navigationDestination(item: $repair) { request in LyricsRepairView(player: player, track: request.track) }
        }.tint(PlayerTheme(scheme).accent)
    }
    private func scroll(_ reader: ScrollViewProxy) {
        guard autoScroll, let active else { return }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { reader.scrollTo(active, anchor: .center) }
    }
    private func edit(synchronize: Bool = false) {
        guard let track = selectedTrack else { return }
        editor = EditorRequest(track: track, synchronize: synchronize)
    }
    private func openRepair() { if let track = selectedTrack { repair = RepairRequest(track: track) } }
    private func load() async {
        guard let track = selectedTrack else { return }
        issue = nil
        if loadedTrackID != track.id { title = track.displayName; artist = ""; loadedLyrics = nil }
        do {
            let snapshot = try await player.readMetadata(for: track)
            let text = try await LyricsAudioPreparation.existingText(track: track, folder: player.folderAccess(for: track),
                                                                   embedded: snapshot.values[.lyrics] ?? "", expected: snapshot.fingerprint)
            try Task.checkCancellation()
            title = snapshot.values[.title] ?? track.displayName; artist = snapshot.values[.artist] ?? ""
            loadedLyrics = LyricsDocument(text: text); loadedTrackID = track.id
            offset = UserDefaults.standard.double(forKey: "lyricsOffset.\(track.id)")
        } catch is CancellationError { }
        catch { issue = error.localizedDescription }
    }
}
