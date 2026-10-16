import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @Bindable var player: PlaybackController
    @Environment(\.colorScheme) private var scheme
    @State private var chooseFolder = false
    @State private var showPlayer = false
    @State private var showSettings = false
    @State private var showQueue = false
    @State private var showLibrary = false
    @State private var search = ""
    private var theme: PlayerTheme { PlayerTheme(scheme) }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                if player.isLoading {
                    HStack {
                        ProgressView().tint(theme.accent)
                        Text("Preparando la carpeta…").font(.subheadline)
                        Spacer()
                        Button("Cancelar") { player.cancelLoading() }
                    }.padding().background(theme.surface)
                }
                if let issue = player.issue {
                    HStack(alignment: .top) {
                        Image(systemName: "exclamationmark.circle")
                        Text(issue).font(.footnote)
                        Spacer()
                        Button { player.issue = nil } label: { Image(systemName: "xmark").frame(width: 44, height: 44) }
                            .accessibilityLabel("Cerrar aviso")
                    }.padding(.leading).background(theme.surface)
                }
                if player.queue.tracks.isEmpty { emptyState }
                else { tracks }
            }
            .background(theme.background)
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if player.current != nil { MiniPlayer(player: player, openPlayer: { showPlayer = true }, openQueue: { showQueue = true }) }
            }
            .fileImporter(isPresented: $chooseFolder, allowedContentTypes: [.folder]) { result in
                switch result {
                case .success(let url): player.chooseFolder(url)
                case .failure(let error): if (error as NSError).code != NSUserCancelledError { player.issue = error.localizedDescription }
                }
            }
            .fullScreenCover(isPresented: $showPlayer) { NowPlayingView(player: player) }
            .sheet(isPresented: $showSettings) { SettingsView(player: player) }
            .sheet(isPresented: $showQueue) { QueueView(player: player) }
            .sheet(isPresented: $showLibrary) { MusicCollectionView(player: player) }
        }
        .tint(theme.accent)
    }
    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("SONORA").font(.caption.weight(.medium)).tracking(3).foregroundStyle(.secondary)
                Spacer()
                Button { showLibrary = true } label: { Image(systemName: "music.note.house").frame(width: 44, height: 44) }.accessibilityLabel("Biblioteca")
                Button { showSettings = true } label: { Image(systemName: "gearshape").frame(width: 44, height: 44) }.accessibilityLabel("Ajustes")
                Button { chooseFolder = true } label: { Image(systemName: "plus").frame(width: 44, height: 44).background(theme.surface, in: .circle) }
                    .accessibilityLabel("Reproducir carpeta")
            }
            Text(player.folderName).font(.system(.largeTitle, design: theme.heading, weight: .bold)).lineLimit(2)
            if !player.queue.tracks.isEmpty {
                Text("\(player.queue.tracks.count) canciones · Incluye subcarpetas").font(.subheadline).foregroundStyle(.secondary)
            }
        }.padding(.horizontal, 24).padding(.top, 8).padding(.bottom, 18)
    }
    private var emptyState: some View {
        VStack(spacing: 22) {
            Spacer()
            Image(systemName: "folder").font(.system(size: 72, weight: .ultraLight)).foregroundStyle(theme.accent)
            Text("Una carpeta.\nToda tu música.").font(.system(.title, design: theme.heading, weight: .semibold)).multilineTextAlignment(.center)
            Text("Elige una carpeta de Archivos o iCloud Drive. Sus canciones y subcarpetas se reproducirán en una sola cola.")
                .foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 310)
            Button { chooseFolder = true } label: {
                Label("Reproducir carpeta", systemImage: "folder.badge.plus").font(.headline).padding(.horizontal, 24).frame(minHeight: 52)
                    .background(theme.accent, in: .capsule).foregroundStyle(scheme == .dark ? Color.black : .white)
            }.accessibilityIdentifier("playFolder")
            Spacer(); Spacer()
        }.padding(24).frame(maxWidth: .infinity)
    }
    private var tracks: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Buscar en esta cola", text: $search).autocorrectionDisabled()
            }.padding(12).background(theme.surface, in: .rect(cornerRadius: 12)).padding(.horizontal, 24).padding(.bottom, 12)
            List {
                ForEach(player.queue.tracks.filter { track in
                    search.isEmpty || track.relativePath.localizedCaseInsensitiveContains(search) ||
                    (player.details[track.id]?.title.localizedCaseInsensitiveContains(search) ?? false) ||
                    (player.details[track.id]?.artist.localizedCaseInsensitiveContains(search) ?? false)
                }) { track in
                    Button {
                        if let index = player.queue.tracks.firstIndex(of: track) { player.play(index: index) }
                    } label: {
                        TrackRow(title: player.details[track.id]?.title ?? track.displayName,
                                 subtitle: player.details[track.id]?.artist ?? (track.folder.isEmpty ? player.folderName : track.folder),
                                 image: player.details[track.id]?.artwork, selected: track.id == player.current?.id)
                    }.buttonStyle(.plain).listRowBackground(theme.background).accessibilityIdentifier("track:" + track.id)
                }
            }.listStyle(.plain).scrollContentBackground(.hidden)
        }
    }
}

struct TrackRow: View {
    let title: String
    let subtitle: String
    let image: UIImage?
    let selected: Bool
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        HStack(spacing: 14) {
            ArtworkView(image: image, cornerRadius: 7).frame(width: 52, height: 52)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.body.weight(.medium)).foregroundStyle(selected ? PlayerTheme(scheme).accent : .primary).lineLimit(2)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if selected { Image(systemName: "waveform").foregroundStyle(PlayerTheme(scheme).accent).accessibilityLabel("Tema actual") }
        }.padding(.vertical, 4).contentShape(.rect)
    }
}
