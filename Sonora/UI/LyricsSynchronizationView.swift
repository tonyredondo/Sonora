import SonoraCore
import SwiftUI

struct LyricsSynchronizationView: View {
    let player: PlaybackController
    let track: AudioTrack
    let current: [MetadataField: String]
    let snapshot: MetadataSnapshot
    let lyrics: String
    let apply: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var settings = MetadataAssistantSettings.shared
    @State private var result: MetadataLookupResult<LyricsSynchronizationResult>?
    @State private var operation: Task<Void, Never>?
    @State private var loading = false
    @State private var operationID: UUID?
    @State private var phase = "Buscando letra sincronizada…"
    @State private var issue: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(current[.title].flatMap { $0.isEmpty ? nil : $0 } ?? track.displayName).font(.headline)
                    Text(current[.artist] ?? "").foregroundStyle(.secondary)
                    if settings.effectiveOffline { Label("Modo desconectado · Solo información guardada", systemImage: "wifi.slash") }
                    Button(settings.effectiveOffline ? "Buscar en caché" : (LyricsDocument(text: lyrics).lines.isEmpty ? "Buscar o transcribir" : (LyricsDocument(text: lyrics).isTimed ? "Sincronizar de nuevo con IA" : "Buscar y sincronizar"))) { start() }
                        .disabled(loading || settings.endpoint.isEmpty).accessibilityIdentifier("synchronizeLyrics")
                    NavigationLink("Configurar asistente") { MetadataConnectionView() }.disabled(loading)
                    if !LyricsDocument(text: lyrics).lines.isEmpty {
                        Text("Usaremos el texto de tu borrador, aunque ya tenga tiempos. La sincronización aparecerá en el editor para escucharla antes de guardar.").font(.footnote).foregroundStyle(.secondary)
                    }
                    Text(LyricsDocument(text: lyrics).isTimed
                        ? "ElevenLabs sincroniza tu texto con el audio. Reutilizamos el análisis guardado si el audio y el texto coinciden; un análisis nuevo envía el audio y consume créditos. Máximo: 10 minutos."
                        : "Buscamos gratis en LRCLIB. Si hay letra, ElevenLabs sincroniza los tiempos; si no, Scribe v2 la transcribe. La IA envía el audio y consume créditos de tu cuenta. Reutilizamos la caché. Máximo: 10 minutos.")
                        .font(.footnote).foregroundStyle(.secondary)
                    if [current[.artist], current[.album]].contains(where: { ($0 ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                        Text("Faltan artista o álbum para buscar una edición en LRCLIB. Puedes completarlos en Información o usar ElevenLabs directamente.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if loading { ProgressView(phase).accessibilityIdentifier("lyricsSynchronizationProgress") }
                    if let issue { ServiceIssueView(message: issue).accessibilityIdentifier("lyricsSynchronizationError") }
                }
                if let result {
                    Section("Vista previa") {
                        Label(sourceName(result.value.source), systemImage: "quote.bubble")
                            .accessibilityIdentifier("lyricsSynchronizationSource")
                        if let attribution = LyricsDocument(text: result.value.text).attribution {
                            Text(attribution).font(.subheadline.weight(.semibold))
                                .accessibilityIdentifier("transcriptionAttribution")
                            Text("La IA puede confundir palabras cantadas. Revisa la letra y los tiempos antes de guardarlos.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        if result.isCached { Label("Guardada para usar sin conexión", systemImage: "internaldrive") }
                        if let warning = result.warning { Text(warning).font(.footnote).foregroundStyle(.secondary) }
                        ForEach(LyricsDocument(text: result.value.text).lines) { line in
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                Text(playbackTime(line.time ?? 0)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                Text(line.text).textSelection(.enabled)
                            }
                        }
                    }
                    Section {
                        Button("Usar en el borrador") { apply(result.value.text); dismiss() }
                            .accessibilityIdentifier("applySynchronizedLyrics")
                        Text("Abre el borrador para revisar la letra y pulsar Guardar. El archivo no cambia hasta que confirmes el guardado.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle(LyricsDocument(text: lyrics).lines.isEmpty ? "Buscar letra" : "Sincronizar letra").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { operation?.cancel(); dismiss() } } }
            .onChange(of: settings.configurationRevision) { cancel() }
            .onChange(of: settings.effectiveOffline) { cancel() }
            .onDisappear { operation?.cancel() }
        }
    }
    private func sourceName(_ source: LyricsSynchronizationResult.Source) -> String {
        switch source {
        case .lrclib: "LRCLIB"
        case .elevenlabs: "ElevenLabs"
        case .elevenlabsTranscription: "ElevenLabs · Scribe v2"
        }
    }
    private func cancel() {
        operation?.cancel(); operation = nil; operationID = nil; loading = false; result = nil; issue = nil
    }
    private func start() {
        operation?.cancel(); loading = true; issue = nil; result = nil; phase = "Buscando letra sincronizada…"
        let id = UUID(); operationID = id
        operation = Task { @MainActor in
            defer { if operationID == id { loading = false; operation = nil } }
            do {
                let connection = try MetadataProxyConnection(endpoint: settings.endpoint, token: settings.savedToken())
                let client = LyricsSynchronizationClient(connection: connection, cache: settings.cache)
                let folder = try player.folderAccess(for: track)
                let query = MetadataSearch(title: current[.title].flatMap { $0.isEmpty ? nil : $0 } ?? track.displayName, artist: (current[.artist] ?? "").trimmingCharacters(in: .whitespacesAndNewlines), album: (current[.album] ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
                let value = try await client.synchronize(query: query, duration: snapshot.duration, lyrics: lyrics, offline: settings.effectiveOffline) {
                    await MainActor.run { phase = "Preparando audio y analizando…" }
                    return try await LyricsAudioPreparation.prepare(track: track, folder: folder, expected: snapshot.fingerprint)
                }
                try Task.checkCancellation()
                result = value
            } catch is CancellationError { }
              catch { if !Task.isCancelled { issue = error.localizedDescription } }
        }
    }
}
