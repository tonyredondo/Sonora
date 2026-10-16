import Foundation
import SonoraCore

struct MetadataProposal: Sendable {
    var values: [MetadataField: String]
    var artwork: Data?
    var lyrics: MetadataLyrics?
    var savedAt: Date?
    var notices: [String]
}

enum MetadataProposalLoader {
    static func load(recording: MetadataRecording, edition: MetadataReleaseChoice?, duration: Double,
                     client: MetadataLookupClient, offline: Bool) async throws -> MetadataProposal {
        var values: [MetadataField: String] = [.title: recording.title, .artist: recording.artist]
        if !recording.genres.isEmpty { values[.genre] = recording.genres.joined(separator: "; ") }
        guard let edition else {
            return MetadataProposal(values: values, notices: ["No se ha elegido una edición. Se propone solo la información de la grabación."])
        }
        let release = try await client.release(edition.id, offline: offline)
        values = release.value.suggestedValues(for: recording)
        var notices = [release.warning].compactMap { $0 }
        if let expected = recording.durationMS, duration.isFinite, abs(Double(expected) / 1000 - duration) > 3 {
            notices.append("La grabación dura \(playbackTime(Double(expected) / 1000)) y tu archivo \(playbackTime(duration)). Comprueba que has elegido la versión correcta.")
        }
        async let cover = artwork(client: client, releaseID: edition.id, offline: offline)
        async let lyrics = lyrics(client: client, title: values[.title] ?? recording.title, artist: recording.artist,
                                  album: release.value.title, duration: duration, offline: offline)
        let (image, words) = try await (cover, lyrics)
        notices.append(contentsOf: [image.notice, words.notice].compactMap { $0 })
        try Task.checkCancellation()
        return MetadataProposal(values: values, artwork: image.value, lyrics: words.value,
                                savedAt: release.savedAt, notices: notices)
    }

    private struct Resource<Value: Sendable>: Sendable {
        let value: Value?
        let notice: String?
    }
    private static func artwork(client: MetadataLookupClient, releaseID: String, offline: Bool) async throws -> Resource<Data> {
        do {
            let response = try await client.artwork(releaseID, offline: offline)
            let worker = Task.detached(priority: .utility) {
                try Task.checkCancellation(); return try ArtworkCodec.prepare(response.value)
            }
            let prepared = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
            try Task.checkCancellation()
            return Resource(value: prepared, notice: response.warning)
        } catch is CancellationError { throw CancellationError() }
        catch MetadataLookupError.unauthorized { throw MetadataLookupError.unauthorized }
        catch MetadataLookupError.notFound { return Resource(value: nil, notice: "Esta edición no tiene carátula disponible.") }
        catch MetadataLookupError.notCached { return Resource(value: nil, notice: "La carátula de esta edición no está guardada en el iPhone.") }
        catch { return Resource(value: nil, notice: "Carátula: " + error.localizedDescription) }
    }
    private static func lyrics(client: MetadataLookupClient, title: String, artist: String, album: String,
                               duration: Double, offline: Bool) async throws -> Resource<MetadataLyrics> {
        guard duration.isFinite, (1...86400).contains(duration), !artist.isEmpty, !album.isEmpty else {
            return Resource(value: nil, notice: "Para buscar letras hacen falta título, artista, álbum y duración del archivo.")
        }
        do {
            let response = try await client.lyrics(title: title, artist: artist, album: album, duration: Int(duration.rounded()), offline: offline)
            try Task.checkCancellation()
            let value = response.value
            if value.instrumental { return Resource(value: nil, notice: "LRCLIB identifica esta grabación como instrumental.") }
            guard !(value.syncedLyrics ?? "").isEmpty || !(value.plainLyrics ?? "").isEmpty else {
                return Resource(value: nil, notice: "No hay letra disponible para esta grabación.")
            }
            return Resource(value: value, notice: response.warning)
        } catch is CancellationError { throw CancellationError() }
        catch MetadataLookupError.unauthorized { throw MetadataLookupError.unauthorized }
        catch MetadataLookupError.notFound { return Resource(value: nil, notice: "No se ha encontrado letra para esta grabación y edición.") }
        catch MetadataLookupError.notCached { return Resource(value: nil, notice: "La letra de esta grabación no está guardada en el iPhone.") }
        catch { return Resource(value: nil, notice: "Letra: " + error.localizedDescription) }
    }
}
