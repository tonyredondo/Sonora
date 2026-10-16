import SonoraCore
import SwiftUI

struct MetadataLookupView: View {
    let player: PlaybackController
    let track: AudioTrack
    let current: [MetadataField: String]
    let hasArtwork: Bool
    let duration: Double
    let apply: ([MetadataField: String], Data?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var settings = MetadataAssistantSettings.shared
    @State private var query: MetadataSearch
    @State private var request: LookupRequest?
    @State private var revision = 0
    @State private var recordings: [MetadataRecording] = []
    @State private var loading = false
    @State private var message: String?
    @State private var savedAt: Date?
    @State private var issue: String?
    @FocusState private var editing: Bool

    private enum LookupRequest: Equatable { case text(MetadataSearch, Int), audio(Int) }
    private struct Run: Equatable {
        let request: LookupRequest?
        let offline: Bool
        let connectionRevision: Int
    }

    init(player: PlaybackController, track: AudioTrack, current: [MetadataField: String], hasArtwork: Bool,
         duration: Double, apply: @escaping ([MetadataField: String], Data?) -> Void) {
        self.player = player; self.track = track; self.current = current; self.hasArtwork = hasArtwork
        self.duration = duration; self.apply = apply
        _query = State(initialValue: MetadataSearch(title: current[.title] ?? track.displayName,
            artist: current[.artist] ?? "", album: current[.album] ?? ""))
    }

    var body: some View {
        NavigationStack {
            Form {
                if settings.effectiveOffline {
                    Section { Label("Modo desconectado · Información guardada en este iPhone", systemImage: "wifi.slash").font(.footnote) }
                }
                Section("Buscar una canción") {
                    TextField("Título", text: $query.title).focused($editing).accessibilityIdentifier("lookupTitle")
                    TextField("Artista", text: $query.artist).focused($editing).accessibilityIdentifier("lookupArtist")
                    TextField("Álbum (opcional)", text: $query.album).focused($editing).accessibilityIdentifier("lookupAlbum")
                    Button(settings.effectiveOffline ? "Buscar en lo guardado" : "Buscar") {
                        editing = false; revision += 1; request = .text(query, revision)
                    }
                    .disabled(query.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || settings.endpoint.isEmpty)
                    .accessibilityIdentifier("metadataSearch")
                    Text("Puedes ajustar estos datos sin cambiar el archivo. Después elegirás la grabación y la edición del disco.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if loading {
                    Section {
                        ProgressView(message ?? "Buscando…")
                        Button("Cancelar búsqueda", role: .cancel) { request = nil }
                    }
                }
                if let issue { Section { Text(issue).foregroundStyle(.secondary).accessibilityIdentifier("metadataLookupIssue") } }
                if let savedAt {
                    Section { CachedMetadataLabel(date: savedAt) }
                }
                if let message, !loading { Section { Text(message).font(.footnote).foregroundStyle(.secondary) } }
                if !recordings.isEmpty {
                    Section("Elige la grabación") {
                        ForEach(recordings) { recording in
                            NavigationLink(value: recording) { RecordingSummary(recording: recording) }
                                .accessibilityIdentifier("recording:\(recording.id)")
                        }
                    }
                } else if request != nil && !loading && issue == nil {
                    Section { Text("Sin coincidencias. Prueba sin el álbum o revisa el título y el artista.").foregroundStyle(.secondary) }
                }
                Section {
                    Button { editing = false; revision += 1; request = .audio(revision) } label: {
                        Label("Reconocer por el audio", systemImage: "waveform")
                    }
                    .disabled(settings.endpoint.isEmpty).accessibilityIdentifier("recognizeMetadata")
                    Text("Sonora calcula una huella de hasta dos minutos en el iPhone. Envía la huella y la duración a AcoustID a través de tu servidor.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section {
                    NavigationLink("Conexión y modo desconectado") { MetadataConnectionView() }
                    Text("Las búsquedas usan MusicBrainz; las letras, LRCLIB; las carátulas, Cover Art Archive. Revisa los resultados antes de guardarlos.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Completar información").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } } }
            .navigationDestination(for: MetadataRecording.self) { recording in
                MetadataEditionView(recording: recording, current: current, hasArtwork: hasArtwork, duration: duration) { values, artwork in
                    apply(values, artwork); dismiss()
                }
            }
            .task(id: Run(request: request, offline: settings.effectiveOffline, connectionRevision: settings.configurationRevision)) {
                await search()
            }
        }
    }

    private func search() async {
        guard let request else { loading = false; message = nil; return }
        loading = true; issue = nil; message = nil; savedAt = nil; recordings = []
        defer { if !Task.isCancelled { loading = false } }
        do {
            let client = try settings.client(), offline = settings.effectiveOffline
            switch request {
            case .text(let query, _):
                let response = try await client.search(query, offline: offline)
                try Task.checkCancellation()
                recordings = response.value; savedAt = response.savedAt; message = response.warning
            case .audio:
                if !offline {
                    let status = try await client.status()
                    guard status.providers["acoustid"].map({ $0.enabled && $0.configured }) == true else { throw MetadataLookupError.recognitionUnavailable }
                }
                message = "Calculando huella del audio…"
                let fingerprint = try await AudioIdentificationService.fingerprint(track: track, folder: player.folderAccess(for: track))
                try Task.checkCancellation(); message = "Buscando coincidencias…"
                let matches = try await client.identify(fingerprint: fingerprint.fingerprint, duration: fingerprint.duration, offline: offline)
                var candidates: [MetadataRecording] = [], failures = 0
                for id in matches.value.recordingIDs {
                    try Task.checkCancellation()
                    do { candidates.append(try await client.recording(id, offline: offline).value) }
                    catch is CancellationError { throw CancellationError() }
                    catch MetadataLookupError.unauthorized { throw MetadataLookupError.unauthorized }
                    catch { failures += 1 }
                }
                try Task.checkCancellation()
                if candidates.isEmpty && failures > 0 { throw offline ? MetadataLookupError.notCached : MetadataLookupError.unavailable }
                recordings = candidates; savedAt = matches.savedAt
                message = failures > 0 ? "Algunas coincidencias no pudieron cargarse. Puedes reintentar la búsqueda." : matches.warning
            }
        } catch is CancellationError { }
        catch {
            guard !Task.isCancelled else { return }
            issue = error.localizedDescription
            if error as? MetadataLookupError == .notCached {
                issue = MetadataLookupError.notCached.localizedDescription + " La búsqueda se reintentará al volver a conectar el asistente."
            }
        }
    }
}

struct RecordingSummary: View {
    let recording: MetadataRecording
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(recording.title).font(.headline)
            Text(recording.artist).foregroundStyle(.secondary)
            let detail = [recording.durationMS.map { playbackTime(Double($0) / 1000) }, recording.disambiguation]
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
            if !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(.secondary) }
        }.padding(.vertical, 3)
    }
}

struct CachedMetadataLabel: View {
    let date: Date
    var body: some View {
        Label("Copia guardada · \(date.formatted(date: .abbreviated, time: .shortened))", systemImage: "internaldrive")
            .font(.footnote).foregroundStyle(.secondary).accessibilityIdentifier("metadataCachedResult")
    }
}

private struct MetadataEditionView: View {
    let recording: MetadataRecording
    let current: [MetadataField: String]
    let hasArtwork: Bool
    let duration: Double
    let apply: ([MetadataField: String], Data?) -> Void
    @State private var settings = MetadataAssistantSettings.shared
    @State private var details: MetadataRecording?
    @State private var issue: String?
    @State private var loading = false
    private var selected: MetadataRecording { details ?? recording }

    var body: some View {
        Form {
            Section { RecordingSummary(recording: selected) }
            if loading { ProgressView("Consultando ediciones…") }
            if let issue { Section { Text(issue).font(.footnote).foregroundStyle(.secondary) } }
            Section("Elige la edición del disco") {
                ForEach(selected.releases) { release in
                    NavigationLink {
                        MetadataProposalView(recording: selected, edition: release, current: current,
                            hasArtwork: hasArtwork, duration: duration, apply: apply)
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(release.title).font(.headline)
                            let detail = [release.date, release.country, release.disambiguation].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
                            if !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(.secondary) }
                        }.padding(.vertical, 3)
                    }.accessibilityIdentifier("release:\(release.id)")
                }
                if selected.releases.isEmpty && !loading {
                    Text("No hay ediciones disponibles para esta grabación.").foregroundStyle(.secondary)
                    NavigationLink("Revisar título y artista") {
                        MetadataProposalView(recording: selected, edition: nil, current: current,
                            hasArtwork: hasArtwork, duration: duration, apply: apply)
                    }
                }
            }
            Section { Text("Comprueba la fecha, el país y la versión para evitar confundir una grabación de estudio con una en directo o una reedición.").font(.footnote).foregroundStyle(.secondary) }
        }
        .navigationTitle("Ediciones").navigationBarTitleDisplayMode(.inline)
        .task(id: settings.effectiveOffline) {
            loading = true; issue = nil
            defer { if !Task.isCancelled { loading = false } }
            do {
                let response = try await settings.client().recording(recording.id, offline: settings.effectiveOffline)
                try Task.checkCancellation(); details = response.value; issue = response.warning
            } catch is CancellationError { }
            catch { if !Task.isCancelled { issue = error.localizedDescription } }
        }
    }
}
