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
                    Button(settings.effectiveOffline ? "Buscar en caché" : "Buscar y sincronizar") { start() }
                        .disabled(loading || settings.endpoint.isEmpty || LyricsDocument(text: lyrics).isTimed).accessibilityIdentifier("synchronizeLyrics")
                    NavigationLink("Configurar asistente") { MetadataConnectionView() }.disabled(loading)
                    Text("Primero buscamos una letra compatible en LRCLIB, gratis. Si faltan los tiempos, enviamos el audio y tu letra a ElevenLabs para sincronizarlos. Ese paso consume créditos de tu cuenta. Admite canciones de hasta 10 minutos.")
                        .font(.footnote).foregroundStyle(.secondary)
                    if LyricsDocument(text: lyrics).isTimed {
                        Text("Esta letra ya tiene tiempos. Puedes ajustarlos en Editar letra.").font(.footnote).foregroundStyle(.secondary)
                    } else if [current[.artist], current[.album]].contains(where: { ($0 ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                        Text("Faltan artista o álbum para buscar una edición en LRCLIB. Puedes completarlos en Información o sincronizar directamente tu letra con ElevenLabs.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if loading { ProgressView(phase).accessibilityIdentifier("lyricsSynchronizationProgress") }
                    if let issue { Text(issue).foregroundStyle(.red).accessibilityIdentifier("lyricsSynchronizationError") }
                }
                if let result {
                    Section("Vista previa") {
                        Label(result.value.source == .lrclib ? "LRCLIB" : "ElevenLabs", systemImage: "quote.bubble")
                            .accessibilityIdentifier("lyricsSynchronizationSource")
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
                        Button("Usar esta letra") { apply(result.value.text); dismiss() }
                            .accessibilityIdentifier("applySynchronizedLyrics")
                        Text("Se añadirá al borrador. Puedes ajustar los tiempos en Editar letra y guardar después la información del archivo.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Sincronizar letra").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { operation?.cancel(); dismiss() } } }
            .onChange(of: settings.configurationRevision) { cancel() }
            .onChange(of: settings.effectiveOffline) { cancel() }
            .onDisappear { operation?.cancel() }
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
                    await MainActor.run { phase = "Preparando audio y sincronizando…" }
                    return try await LyricsAudioPreparation.prepare(track: track, folder: folder, expected: snapshot.fingerprint)
                }
                try Task.checkCancellation()
                result = value
            } catch is CancellationError { }
              catch { if !Task.isCancelled { issue = error.localizedDescription } }
        }
    }
}
