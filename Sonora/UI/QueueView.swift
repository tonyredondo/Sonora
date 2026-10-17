import SwiftUI
import SonoraCore
import UniformTypeIdentifiers

struct QueueView: View {
    @Bindable var player: PlaybackController
    @Environment(\.dismiss) private var dismiss
    @State private var editingTrack: AudioTrack?
    @State private var chooseFolder = false
    @State private var volumeSelection: VolumeAnalysisSelection?
    var body: some View {
        NavigationStack {
            List {
                if player.isLoading { HStack { ProgressView("Preparando carpeta…"); Button("Cancelar") { player.cancelLoading() } } }
                ForEach(player.queue.tracks) { track in
                    Button {
                        if let index = player.queue.tracks.firstIndex(of: track) { player.play(index: index) }
                    } label: {
                        TrackRow(player: player, track: track, showsLocation: true)
                    }.buttonStyle(.plain).accessibilityIdentifier("queue-track:" + track.id).contextMenu {
                        Button("Reproducir a continuación") { player.enqueue(track, playNext: true) }
                        Button(player.isFavorite(track) ? "Quitar de favoritos" : "Marcar como favorita", systemImage: "heart") { player.toggleFavorite(track) }
                        if let id = player.libraryID(for: track) {
                            Menu("Añadir a playlist") { ForEach(player.library.state.playlists) { list in Button(list.name) { player.library.add([id], to: list.id) } } }
                        }
                        Button("Editar información", systemImage: "info.circle") { editingTrack = track }
                        Button("Analizar volumen", systemImage: "waveform") { volumeSelection = .init(tracks: [track]) }
                    }
                }.onMove { player.move(from: $0, to: $1) }.onDelete { player.remove(at: $0) }
            }
            .navigationTitle("Cola · \(player.queue.tracks.count)")
            .sheet(item: $editingTrack) { MetadataEditorView(player: player, track: $0) }
            .sheet(item: $volumeSelection) { VolumeAnalysisView(player: player, selection: $0) }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { EditButton() }
                ToolbarItem(placement: .primaryAction) { Button { chooseFolder = true } label: { Image(systemName: "folder.badge.plus") }.accessibilityLabel("Añadir carpeta a la cola").disabled(player.isLoading) }
                ToolbarItem(placement: .confirmationAction) { Button("Listo") { dismiss() } }
                ToolbarItem(placement: .bottomBar) {
                    Button("Analizar volumen", systemImage: "waveform") { volumeSelection = .init(tracks: player.queue.tracks) }.disabled(player.queue.tracks.isEmpty)
                }
            }
            .fileImporter(isPresented: $chooseFolder, allowedContentTypes: [.folder]) { result in
                switch result { case .success(let url): player.chooseAdditionalFolder(url); case .failure(let error): if (error as NSError).code != NSUserCancelledError { player.issue = error.localizedDescription } }
            }
        }
    }
}
