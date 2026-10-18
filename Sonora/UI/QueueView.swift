import SwiftUI
import SonoraCore
import UniformTypeIdentifiers

struct QueueView: View {
    @Bindable var player: PlaybackController
    @Environment(\.dismiss) private var dismiss
    @State private var action: SongActionRequest?
    @State private var chooseFolder = false
    @State private var editMode: EditMode = .inactive
    var body: some View {
        NavigationStack {
            List {
                if player.isLoading { HStack { ProgressView("Preparando carpeta…"); Button("Cancelar") { player.cancelLoading() } } }
                if editMode.isEditing {
                    ForEach(player.queue.tracks) { track in row(track) }
                        .onMove { player.move(from: $0, to: $1) }.onDelete { player.remove(at: $0) }
                } else if let index = player.queue.currentIndex {
                    queueSection("Ya reproducidas", tracks: Array(player.queue.tracks.prefix(index)))
                    queueSection("Ahora", tracks: Array(player.queue.tracks[index...index]))
                    queueSection("A continuación", tracks: Array(player.queue.tracks.dropFirst(index + 1)))
                } else {
                    ContentUnavailableView("La cola está vacía", systemImage: "music.note.list", description: Text("Reproduce música o añade canciones desde sus opciones."))
                }
            }
            .environment(\.editMode, $editMode)
            .navigationTitle("Cola · \(player.queue.tracks.count)")
            .sheet(item: $action) { SongActionSheet(player: player, request: $0) }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(editMode.isEditing ? "Terminar" : "Reordenar") { editMode = editMode.isEditing ? .inactive : .active }
                        .disabled(player.queue.tracks.isEmpty)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Añadir carpeta a la cola", systemImage: "folder.badge.plus") { chooseFolder = true }.disabled(player.isLoading)
                }
                ToolbarItem(placement: .confirmationAction) { Button("Listo") { dismiss() } }
            }
            .fileImporter(isPresented: $chooseFolder, allowedContentTypes: [.folder]) { result in
                switch result {
                case .success(let url): player.chooseAdditionalFolder(url)
                case .failure(let error): if (error as NSError).code != NSUserCancelledError { player.issue = error.localizedDescription }
                }
            }
        }
    }
    @ViewBuilder private func queueSection(_ title: String, tracks: [AudioTrack]) -> some View {
        if !tracks.isEmpty {
            Section(title) {
                ForEach(tracks) { track in row(track) }
                    .onDelete { offsets in
                        let ids = Set(offsets.map { tracks[$0].id })
                        player.remove(at: IndexSet(player.queue.tracks.indices.filter { ids.contains(player.queue.tracks[$0].id) }))
                    }
            }
        }
    }
    private func row(_ track: AudioTrack) -> some View {
        HStack {
            Button {
                if let index = player.queue.tracks.firstIndex(of: track) { player.play(index: index) }
            } label: { TrackRow(player: player, track: track) }
                .buttonStyle(.plain).accessibilityIdentifier("queue-track:" + track.id)
            if !editMode.isEditing {
                Menu { SongActions(player: player, track: track) { action = $0 } } label: {
                    Image(systemName: "ellipsis").frame(width: 44, height: 44)
                }.accessibilityLabel("Opciones de canción").accessibilityIdentifier("queue-options:" + track.id)
            }
        }.contextMenu { SongActions(player: player, track: track) { action = $0 } }
    }
}
