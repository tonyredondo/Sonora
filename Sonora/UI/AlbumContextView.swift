import SonoraCore
import SwiftUI

/// Reads shared preparation state only. Swiping here never spends a new request.
struct AlbumContextView: View {
    let player: PlaybackController
    @AppStorage("lyricMeaningLanguage") private var language = "es"
    @AppStorage("prepareQueueMeaning") private var automatic = true
    @AppStorage("prepareQueueCharacter") private var character = true

    var body: some View {
        let album = player.currentAlbum
        let key = album.map { player.albumInterpretations.key($0, language: language, character: character) }
        let result = key.flatMap { player.albumInterpretations.results[$0] }
        let status = key.flatMap { player.albumInterpretations.statuses[$0] }
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let result {
                    Text("Sobre el álbum").font(.headline).accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier("playerAlbumTitle")
                    Text(result.title).font(.subheadline).foregroundStyle(.secondary)
                    Text(result.interpretation.explanation).font(.body)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                        .accessibilityIdentifier("playerAlbumText")
                    if result.missingLyrics > 0 {
                        Text("Letras usadas en el análisis: \(result.trackCount - result.missingLyrics) de \(result.trackCount) canciones.")
                            .font(.caption).foregroundStyle(.secondary)
                            .accessibilityIdentifier("playerAlbumCoverage")
                    }
                    Text("Interpretación de IA").font(.caption).foregroundStyle(.secondary)
                } else {
                    if status?.busy == true || player.library.isIndexing { ProgressView() }
                    Text(message(status)).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("playerAlbumPreparation")
                }
                if case .failed = status, let album {
                    Button("Reintentar") {
                        Task { try? await player.refreshAlbum(album, language: language, character: character) }
                    }.accessibilityIdentifier("retryAlbum")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24).padding(.top, 24)
        }
        .contentMargins(.bottom, 104, for: .scrollContent)
        .accessibilityIdentifier("playerAlbum")
    }
    private func message(_ status: AlbumInterpretationStore.Status?) -> String {
        if case .failed(let error) = status { return error }
        if player.library.isIndexing { return "Leyendo las canciones del álbum…" }
        if status == .collecting { return "Reuniendo las letras y etiquetas del álbum…" }
        if status == .interpreting { return "Preparando «Sobre el álbum»…" }
        if !automatic { return "El significado automático está desactivado." }
        if let issue = player.albumInterpretations.automaticIssue { return issue }
        if player.albumInterpretations.waitingForConnection { return "Pendiente de conexión con el servidor." }
        return "Análisis del álbum en cola…"
    }
}
