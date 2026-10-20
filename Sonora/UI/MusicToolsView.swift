import SonoraCore
import SwiftUI

struct PlaybackAdjustmentControls: View {
    let player: PlaybackController
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dynamicTypeSize) private var typeSize
    var body: some View {
        Section {
            VStack(spacing: 0) {
                if typeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 4) { Text("Velocidad"); rateLabel }.frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    HStack { Label("Velocidad", systemImage: "speedometer"); Spacer(); rateLabel }
                }
                MediaSlider(value: Binding(get: { Double(player.equalizer.playback.rate) }, set: { player.setPlaybackAdjustment(rate: Float($0)) }),
                            range: 0.5...2, tint: PlayerTheme(scheme).accent, label: "Velocidad sin cambiar el tono")
                    .frame(height: 44).accessibilityIdentifier("playbackRate")
            }
            VStack(alignment: .leading, spacing: 4) {
                if typeSize.isAccessibilitySize { Text("Tonalidad"); pitchLabel }
                Stepper(value: Binding(get: { Int(player.equalizer.playback.semitones) }, set: { player.setPlaybackAdjustment(semitones: Float($0)) }), in: -12...12) {
                    if !typeSize.isAccessibilitySize { LabeledContent { pitchLabel } label: { Text("Tonalidad") } }
                }.accessibilityLabel("Tonalidad").accessibilityValue(String(format: "%+d semitonos", Int(player.equalizer.playback.semitones)))
                    .accessibilityIdentifier("playbackPitch")
            }
            Button("Restablecer velocidad y tono") { player.setPlaybackAdjustment(rate: 1, semitones: 0) }
                .disabled(player.equalizer.playback.isOriginal)
        } header: { Text("Velocidad y tono") } footer: {
            Text("Se aplican a la reproducción y a la previsualización de letras. Los tiempos siguen indicando la posición en el audio original.")
        }
    }
    private var rateLabel: some View { Text(player.equalizer.playback.rate.formatted(.number.precision(.fractionLength(2))) + "×").monospacedDigit() }
    private var pitchLabel: some View { Text(String(format: "%+d semitonos", Int(player.equalizer.playback.semitones))).monospacedDigit().foregroundStyle(.secondary) }
}

struct WaveformTimeline: View {
    let analysis: SongAnalysis
    var markers: [SongMarker] = []
    let position: Double
    let seek: (Double) -> Void
    @State private var scrub: Double?
    @Environment(\.colorScheme) private var scheme
    private var time: Double { scrub ?? position }
    var body: some View {
        Canvas { context, size in
            let width = max(1, Int(size.width / 3)), fraction = min(1, max(0, time / analysis.duration))
            let levels = analysis.waveformLevels(count: width)
            for (index, amplitude) in levels.enumerated() {
                let height = max(2, CGFloat(amplitude) * (size.height - 8))
                let rect = CGRect(x: CGFloat(index) * size.width / CGFloat(levels.count), y: (size.height - height) / 2, width: 2, height: height)
                context.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(Double(index) / Double(levels.count) <= fraction ? PlayerTheme(scheme).accent : .secondary.opacity(0.4)))
            }
            for marker in markers {
                let x = marker.time / analysis.duration * size.width
                context.fill(Path(CGRect(x: x, y: 0, width: 2, height: 8)), with: .color(.primary))
            }
        }
        .frame(height: 48).contentShape(.rect)
        .overlay { GeometryReader { geometry in
            Color.clear.contentShape(.rect).gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in scrub = min(analysis.duration, max(0, value.location.x / max(1, geometry.size.width) * analysis.duration)) }
                .onEnded { _ in if let scrub { seek(min(max(0, analysis.duration - 0.01), scrub)) }; scrub = nil })
        } }
        .accessibilityElement(children: .ignore).accessibilityLabel("Forma de onda, posición de reproducción")
        .accessibilityValue(playbackTime(time) + " de " + playbackTime(analysis.duration))
        .accessibilityAdjustableAction { direction in
            seek(min(max(0, analysis.duration - 0.01), max(0, position + (direction == .increment ? 5 : -5))))
        }.accessibilityIdentifier("songWaveform")
    }
}

struct SongAnalysisView: View {
    let player: PlaybackController
    let track: AudioTrack
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var result: SongToolsResult?
    @State private var progress = 0.0
    @State private var issue: String?
    @State private var refresh = UUID()
    @State private var editingBPM = false
    @State private var bpmText = ""
    @State private var tapping = false
    @State private var taps: [Double] = []
    @State private var marker: SongMarker?
    @State private var saving = false
    private var time: Double { player.isEditingTrackCurrent(track) ? player.currentTime : 0 }

    var body: some View {
        List {
            if let result {
                Section {
                    CompactActionHeader {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(result.bpm.map { String(format: "%.0f BPM", $0.rounded()) } ?? "BPM no detectado").font(.title2.bold()).monospacedDigit().accessibilityIdentifier("songBPM")
                            Text(result.annotations.bpm != nil ? "Corregido por ti" : result.analysis.tempo.variable ? "Estimado · ritmo variable" : "Estimado")
                                .font(.caption).foregroundStyle(.secondary)
                            if result.annotations.bpm == nil, result.bpm != nil {
                                Text(result.analysis.tempo.confidence >= 0.7 ? "Confianza alta" : result.analysis.tempo.confidence >= 0.4 ? "Confianza media" : "Confianza baja · aproximado")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    } actions: {
                        CompactActionRow(layout: .inline) {
                            Button { bpmText = result.bpm.map { String(format: "%.0f", $0.rounded()) } ?? ""; editingBPM = true } label: { CompactActionLabel(title: "Corregir BPM", icon: "pencil", caption: "BPM") }
                            Button { taps = []; tapping = true } label: { CompactActionLabel(title: "Marcar ritmo con toques", icon: "hand.tap", caption: "Toques") }
                        }
                    }
                }.compactActionListRow()
                Section {
                    WaveformTimeline(analysis: result.analysis, markers: result.annotations.markers, position: time, seek: seek)
                    if typeSize.isAccessibilitySize {
                        VStack(alignment: .leading, spacing: 8) { markerControls(result) }
                    } else {
                        HStack { markerControls(result) }
                    }
                } header: { Text("Forma de onda") }
                Section {
                    if result.annotations.markers.isEmpty { Text("Marca estribillos, solos o cualquier punto que quieras volver a escuchar.").font(.subheadline).foregroundStyle(.secondary) }
                    ForEach(result.annotations.markers) { item in
                        Group {
                            if typeSize.isAccessibilitySize {
                                VStack(alignment: .leading, spacing: 8) { markerPlayback(item); markerEdit(item) }
                            } else {
                                HStack { markerPlayback(item); markerEdit(item) }
                            }
                        }
                        .swipeActions { Button("Eliminar", role: .destructive) { var value = result.annotations; value.markers.removeAll { $0.id == item.id }; save(value) } }
                    }
                } header: { Text("Marcadores") }
            } else if issue == nil {
                Section {
                    ProgressView(progress > 0 ? "Analizando audio…" : "Identificando audio…", value: progress)
                    Text("La forma de onda y el BPM se guardan para reutilizarlos.").font(.footnote).foregroundStyle(.secondary)
                }
            }
            if let issue {
                Section {
                    Text(issue).foregroundStyle(.red)
                    if result == nil { Button("Reintentar") { refresh = UUID() } }
                }
            }
        }
        .compactContentSpacing().navigationTitle("BPM y marcadores").navigationBarTitleDisplayMode(.inline)
        .disabled(saving)
        .safeAreaInset(edge: .bottom) { if let result { LyricsEditingTransport(player: player, track: track, duration: result.analysis.duration, offersAnalysis: false) } }
        .task(id: "\(track.id):\(refresh)") {
            result = nil; issue = nil; progress = 0
            do {
                let snapshot = try await player.readMetadata(for: track)
                result = try await player.musicTools.load(track: track, folder: player.folderAccess(for: track), expected: snapshot.fingerprint) { value in
                    Task { @MainActor in progress = value }
                }
            } catch is CancellationError { }
            catch { if !Task.isCancelled { issue = error.localizedDescription } }
        }
        .alert("Corregir BPM", isPresented: $editingBPM) {
            TextField("BPM", text: $bpmText).keyboardType(.decimalPad)
            Button("Guardar") {
                guard let result, let bpm = Double(bpmText.replacingOccurrences(of: ",", with: ".")) else { issue = "Introduce un BPM entre 40 y 300."; return }
                var value = result.annotations; value.bpm = bpm; save(value)
            }
            Button("Usar estimación") { if var value = result?.annotations { value.bpm = nil; save(value) } }
            Button("Cancelar", role: .cancel) { }
        } message: { Text("Solo cambia el dato guardado; la reproducción conserva su velocidad.") }
        .sheet(isPresented: $tapping) {
            NavigationStack {
                VStack(spacing: 16) {
                    Text(TapTempo.bpm(taps: taps).map { String(format: "%.0f BPM", $0.rounded()) } ?? "Da al menos cuatro toques").font(.title2).monospacedDigit()
                    Button {
                        let now = ProcessInfo.processInfo.systemUptime
                        if let last = taps.last, now - last > 1.5 { taps = [] }
                        taps.append(now); taps = Array(taps.suffix(9))
                    } label: { Label("Marcar pulso", systemImage: "hand.tap").padding(28) }.buttonStyle(.bordered)
                    Button("Guardar BPM") {
                        if var value = result?.annotations, let bpm = TapTempo.bpm(taps: taps) { value.bpm = bpm; save(value); tapping = false }
                    }.disabled(TapTempo.bpm(taps: taps) == nil)
                }.padding().navigationTitle("Marcar ritmo").navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cerrar") { tapping = false } } }
            }.presentationDetents([.medium, .large])
        }
        .sheet(item: $marker) { item in
            if let result { SongMarkerEditor(marker: item, duration: result.analysis.duration) { edited in
                var value = result.annotations; value.markers.removeAll { $0.id == edited.id }; value.markers.append(edited)
                self.result = try await player.musicTools.save(value, for: track, folder: player.folderAccess(for: track), result: result)
            } }
        }
    }
    @ViewBuilder private func markerControls(_ result: SongToolsResult) -> some View {
        Text(playbackTime(time) + " / " + playbackTime(result.analysis.duration)).font(.caption.monospacedDigit())
        if !typeSize.isAccessibilitySize { Spacer() }
        Button { marker = SongMarker(time: min(time, max(0, result.analysis.duration - 0.01)), title: "Marcador") } label: { Label("Marcar", systemImage: "bookmark") }
            .accessibilityIdentifier("addSongMarker")
    }
    private func markerPlayback(_ item: SongMarker) -> some View {
        Button { player.playForLyricsEditing(track, at: item.time) } label: {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.title).fixedSize(horizontal: false, vertical: true)
                    Label(playbackTime(item.time), systemImage: "play.fill").font(.caption.monospacedDigit())
                }.frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack { Image(systemName: "play.fill"); Text(item.title); Spacer(); Text(playbackTime(item.time)).monospacedDigit() }.frame(minHeight: 44)
            }
        }.buttonStyle(.plain).accessibilityLabel("Escuchar \(item.title), \(playbackTime(item.time))")
    }
    private func markerEdit(_ item: SongMarker) -> some View {
        Button { marker = item } label: {
            if typeSize.isAccessibilitySize { Label("Editar", systemImage: "pencil").font(.caption).frame(minHeight: 44) }
            else { Image(systemName: "pencil").frame(width: 44, height: 44) }
        }.buttonStyle(.plain).accessibilityLabel("Editar \(item.title)")
    }
    private func seek(_ time: Double) {
        if player.isEditingTrackCurrent(track) { player.seek(to: time) }
        else { player.playForLyricsEditing(track, at: time) }
    }
    private func save(_ value: SongAnnotations) {
        guard let result else { return }
        saving = true
        Task { @MainActor in
            defer { saving = false }
            do { self.result = try await player.musicTools.save(value, for: track, folder: player.folderAccess(for: track), result: result); issue = nil }
            catch { issue = error.localizedDescription }
        }
    }
}

private struct SongMarkerEditor: View {
    @State private var marker: SongMarker
    init(marker: SongMarker, duration: Double, save: @escaping (SongMarker) async throws -> Void) {
        _marker = State(initialValue: marker); self.duration = duration; self.save = save
    }
    let duration: Double
    let save: (SongMarker) async throws -> Void
    @State private var issue: String?
    @State private var saving = false
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                TextField("Nombre", text: $marker.title).accessibilityIdentifier("markerName")
                TextField("Inicio en segundos", value: $marker.time, format: .number).keyboardType(.decimalPad).monospacedDigit()
                Text("Duración: \(playbackTime(duration))").font(.footnote)
                if let issue { Text(issue).foregroundStyle(.red) }
            }.navigationTitle("Marcador").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() }.disabled(saving) }
                    ToolbarItem(placement: .confirmationAction) { Button("Guardar") {
                        saving = true
                        Task { @MainActor in
                            defer { saving = false }
                            do { try await save(marker); dismiss() } catch { issue = error.localizedDescription }
                        }
                    }.disabled(saving) }
                }.interactiveDismissDisabled(saving)
        }
    }
}
