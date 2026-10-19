import SonoraCore
import SwiftUI

/// All edits stay in the parent metadata draft, including results from AI.
struct LyricsDraftEditor: View {
    let player: PlaybackController
    let track: AudioTrack
    let duration: Double
    @Binding var text: String
    @State private var mode = Mode.text
    @State private var draft = LyricsDraft(text: "")
    let editPhrase: (LyricsDraft, LyricsDraft.Line) -> Void
    @FocusState private var editingText: Bool
    private enum Mode: String, CaseIterable { case text = "Texto", phrases = "Frases" }

    var body: some View {
        Section {
            Picker("Vista del borrador", selection: $mode) {
                ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).accessibilityIdentifier("lyricsDraftMode")
            if mode == .text {
                TextEditor(text: $text).frame(minHeight: 240).focused($editingText).accessibilityLabel("Texto de la letra").accessibilityIdentifier("metadata-lyrics")
                Text("En Frases puedes editar cada línea y su inicio. Previsualizar sigue este borrador con la música; solo Guardar cambia el archivo.")
                    .font(.footnote).foregroundStyle(.secondary)
            } else if draft.lines.isEmpty {
                Text("Añade el texto de la letra para empezar.").foregroundStyle(.secondary)
            } else if mode == .phrases {
                ForEach(draft.lines) { line in
                    Button { editPhrase(draft, line) } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(line.time.map { String(LyricsDraft.timestamp($0).dropFirst().dropLast()) } ?? "Sin tiempo")
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            Text(line.text.isEmpty ? "♪" : line.text).foregroundStyle(.primary).frame(maxWidth: .infinity, alignment: .leading)
                            Image(systemName: "pencil")
                        }.frame(minHeight: 44).contentShape(.rect)
                    }.buttonStyle(.plain).accessibilityIdentifier("draft-phrase-\(line.id)")
                }
            }
        }
        .toolbar { ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("Ocultar teclado") { editingText = false } } }
        .onChange(of: text, initial: true) { draft = LyricsDraft(text: text) }
    }
}

struct LyricsDraftPreview: View {
    let player: PlaybackController
    let track: AudioTrack
    let draft: LyricsDraft
    let duration: Double
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var follow = true
    private var active: String? {
        guard player.isEditingTrackCurrent(track) else { return nil }
        let offset = UserDefaults.standard.double(forKey: "lyricsOffset.\(track.id)")
        let time = player.currentTime - offset + 0.25
        var selected: LyricsDraft.Line?
        for line in draft.lines {
            if let start = line.time, start <= time, start >= (selected?.time ?? -.infinity) { selected = line }
        }
        return selected?.id
    }
    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text(track.displayName).font(.headline).lineLimit(2).padding(.horizontal)
                Toggle("Seguir la canción", isOn: $follow).padding(.horizontal)
                if draft.lines.contains(where: { $0.time == nil }) {
                    Text("Las frases sin tiempo no siguen la música. Asígnales un inicio en Frases o sincroniza el borrador.")
                        .font(.footnote).foregroundStyle(.secondary).padding(.horizontal)
                }
                Divider()
                if draft.lines.isEmpty {
                    ContentUnavailableView("El borrador está vacío", systemImage: "quote.bubble", description: Text("Vuelve al editor para escribir, buscar o transcribir la letra.")).frame(maxHeight: .infinity)
                } else {
                ScrollViewReader { reader in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 22) {
                            ForEach(draft.lines) { line in
                                Button {
                                    if let time = line.time { player.playForLyricsEditing(track, at: max(0, time + UserDefaults.standard.double(forKey: "lyricsOffset.\(track.id)"))) }
                                } label: {
                                    Text(line.text.isEmpty ? "♪" : line.text)
                                        .font(active == line.id ? .title.bold() : .title2.weight(.medium))
                                        .foregroundStyle(active == line.id ? PlayerTheme(scheme).accent : .primary)
                                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                }.buttonStyle(.plain).disabled(line.time == nil).id(line.id)
                                    .accessibilityValue(active == line.id ? "Línea actual del borrador" : "")
                                    .accessibilityIdentifier("draft-preview-\(line.id)")
                            }
                        }.padding(24)
                    }.accessibilityIdentifier("draftLyricsPreview")
                        .onChange(of: active, initial: true) { scroll(reader) }
                        .onChange(of: follow) { scroll(reader) }
                }
                }
            }
            .padding(.top, 12).background(PlayerTheme(scheme).background)
            .safeAreaInset(edge: .bottom) { LyricsEditingTransport(player: player, track: track, duration: duration) }
            .navigationTitle("Previsualizar borrador").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Volver a editar") { dismiss() }.accessibilityIdentifier("closeDraftPreview") }
            }
        }
    }
    private func scroll(_ reader: ScrollViewProxy) {
        guard follow, let active else { return }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { reader.scrollTo(active, anchor: .center) }
    }
}

struct LyricsEditingTransport: View {
    let player: PlaybackController
    let track: AudioTrack
    let duration: Double
    var preview: (() -> Void)? = nil
    @State private var scrub: Double?
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dynamicTypeSize) private var textSize
    private var current: Bool { player.isEditingTrackCurrent(track) }
    private var time: Double { current ? player.currentTime : 0 }
    private var playing: Bool { current && (player.isPlaying || player.isPreparing) }
    var body: some View {
        VStack(spacing: 4) {
            if textSize.isAccessibilitySize {
                if let preview {
                    Button("Previsualizar", systemImage: "play.rectangle", action: preview)
                        .font(.caption).frame(maxWidth: .infinity, minHeight: 44).accessibilityIdentifier("openDraftPreview")
                }
            } else {
                HStack {
                    Text(current ? "Escuchar mientras editas" : "Escuchar esta canción").foregroundStyle(.secondary)
                    if let preview {
                        Spacer(minLength: 8)
                        Button("Previsualizar", systemImage: "play.rectangle", action: preview)
                            .frame(minHeight: 44).accessibilityIdentifier("openDraftPreview")
                    }
                }.font(.caption)
            }
            if textSize.isAccessibilitySize {
                HStack(spacing: 24) { transportButtons }
                position
            } else {
                HStack(spacing: 16) {
                    transportButtons
                    Spacer(minLength: 0)
                    position
                }
            }
            MediaSlider(value: Binding(get: { scrub ?? time }, set: { scrub = $0 }), range: 0...max(0.01, duration), tint: PlayerTheme(scheme).accent, label: "Posición para revisar la letra") { editing in
                if !editing, let scrub { seek(scrub); self.scrub = nil }
            }.frame(height: 30).accessibilityIdentifier("draftPlaybackTimeline")
            if let issue = player.issue { Text(issue).font(.caption).foregroundStyle(.red).lineLimit(2) }
        }.padding(.horizontal).padding(.vertical, 8).background(.bar)
            .disabled(duration <= 0 || player.isDeletingFiles)
    }
    private var position: some View {
        Text("\(playbackTime(scrub ?? time)) / \(playbackTime(duration))").font(.caption.monospacedDigit())
            .accessibilityIdentifier("draftPlaybackPosition")
    }
    private var transportButtons: some View {
        Group {
            Button("Retroceder 5 segundos", systemImage: "gobackward.5") { seek(max(0, time - 5)) }
                .labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44).accessibilityIdentifier("draftSkipBack")
            Button {
                if playing { player.pause() } else { player.playForLyricsEditing(track) }
            } label: { Image(systemName: playing ? "pause.fill" : "play.fill").font(.title2).frame(minWidth: 44, minHeight: 44) }
                .accessibilityLabel(playing ? "Pausar previsualización" : "Reproducir previsualización").accessibilityIdentifier("draftPlayback")
            Button("Adelantar 5 segundos", systemImage: "goforward.5") { seek(min(max(0, duration - 0.01), time + 5)) }
                .labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44).accessibilityIdentifier("draftSkipForward")
        }
    }
    private func seek(_ time: Double) {
        if current { player.seek(to: time) }
        else { player.playForLyricsEditing(track, at: time) }
    }
}

struct LyricsPhraseEditor: View {
    let player: PlaybackController
    let track: AudioTrack
    let duration: Double
    let draft: LyricsDraft
    let line: LyricsDraft.Line
    let apply: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var start = ""
    @State private var issue: String?
    @State private var discard = false
    private var offset: Double { UserDefaults.standard.double(forKey: "lyricsOffset.\(track.id)") }
    private var changed: Bool { text != line.text || start != (line.time.map { String(LyricsDraft.timestamp($0).dropFirst().dropLast()) } ?? "") }
    private var seconds: Double? {
        let parts = start.replacingOccurrences(of: ",", with: ".").split(separator: ":", omittingEmptySubsequences: false)
        if parts.count == 2, let minutes = Double(parts[0]), let seconds = Double(parts[1]), minutes >= 0, seconds >= 0, seconds < 60 { return minutes * 60 + seconds }
        return parts.count == 1 ? Double(parts[0]) : nil
    }
    var body: some View {
        NavigationStack {
            Form {
                Section("Frase") { TextField("Texto de la frase", text: $text, axis: .vertical).lineLimit(2...6).accessibilityIdentifier("draftPhraseText") }
                Section("Inicio") {
                    TextField("mm:ss.mmm o segundos", text: $start).keyboardType(.numbersAndPunctuation).accessibilityIdentifier("draftPhraseTime")
                    CompactActionRow {
                        Button { setTime(max(0, (seconds ?? 0) - 0.1)) } label: {
                            CompactActionLabel(title: "Adelantar una décima", icon: "minus", caption: "−0,1 s")
                        }
                        Button { setTime(min(max(0, duration - 0.001), (seconds ?? 0) + 0.1)) } label: {
                            CompactActionLabel(title: "Retrasar una décima", icon: "plus", caption: "+0,1 s")
                        }
                        Button { setTime(max(0, player.currentTime - offset)) } label: {
                            CompactActionLabel(title: "Usar posición de reproducción", icon: "scope", caption: "Ahora")
                        }.disabled(!player.isEditingTrackCurrent(track))
                        Button { if let seconds { player.playForLyricsEditing(track, at: max(0, seconds + offset - 0.5)) } } label: {
                            CompactActionLabel(title: "Escuchar desde este inicio", icon: "play.fill", caption: "Escuchar")
                        }.disabled(seconds.map { !$0.isFinite || $0 < 0 || $0 >= duration } ?? true)
                    }
                    Text("Puedes dejar un inicio pendiente en el borrador. Para guardar una letra sincronizada, todas sus frases necesitan un tiempo.").font(.footnote).foregroundStyle(.secondary)
                }
                if let issue { Text(issue).foregroundStyle(.red) }
            }
            .safeAreaInset(edge: .bottom) { LyricsEditingTransport(player: player, track: track, duration: duration) }
            .navigationTitle("Editar frase").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { if changed { discard = true } else { dismiss() } } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Aplicar") {
                        do {
                            guard start.trimmingCharacters(in: .whitespaces).isEmpty || seconds != nil else { throw LyricsRepairError.invalidTiming }
                            apply(try draft.replacing(line.id, text: text, time: seconds, duration: duration)); dismiss()
                        } catch { issue = error.localizedDescription }
                    }.accessibilityLabel("Aplicar al borrador").accessibilityIdentifier("applyDraftPhrase")
                }
            }
            .interactiveDismissDisabled(changed)
            .alert("Hay cambios en esta frase", isPresented: $discard) {
                Button("Descartar frase", role: .destructive) { dismiss() }
                Button("Seguir editando", role: .cancel) { }
            }
            .onAppear { text = line.text; if let time = line.time { setTime(time) } }
        }
    }
    private func setTime(_ time: Double) { start = String(LyricsDraft.timestamp(time).dropFirst().dropLast()) }
}
