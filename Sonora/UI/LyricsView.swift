import SonoraCore
import SwiftUI

struct LyricsView: View {
    let player: PlaybackController
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("lyricsAutoScroll") private var autoScroll = true
    @State private var offset: Double = 0
    @State private var editingTrack: AudioTrack?
    private var lyrics: LyricsDocument { player.currentDetails?.lyrics ?? LyricsDocument(text: "") }
    private var active: Int? { lyrics.activeLine(at: player.currentTime, offset: offset) }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if lyrics.lines.isEmpty {
                    ContentUnavailableView {
                        Label("Sin letra", systemImage: "quote.bubble")
                    } description: {
                        Text("Añade una letra en la información de la canción o coloca un archivo .lrc junto al audio.")
                    } actions: { Button("Añadir letra") { editingTrack = player.current } }
                } else {
                    if lyrics.isTimed {
                        VStack {
                            Toggle("Seguir la letra", isOn: $autoScroll)
                            HStack {
                                Text("Ajuste \(offset, specifier: "%+.1f") s").monospacedDigit().font(.caption)
                                MediaSlider(value: $offset, range: -5...5, tint: PlayerTheme(scheme).accent, label: "Ajuste de sincronización")
                                    .frame(height: 44).accessibilityIdentifier("lyricsOffset")
                            }
                        }.padding(.horizontal)
                    }
                    ScrollViewReader { reader in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 22) {
                                ForEach(lyrics.lines) { line in
                                    if let time = line.time {
                                        Button { player.seek(to: max(0, time + offset)) } label: {
                                            Text(line.text.isEmpty ? "♪" : line.text).font(.title2.weight(active == line.id ? .bold : .medium))
                                                .foregroundStyle(active == line.id ? PlayerTheme(scheme).accent : .primary)
                                                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                        }.buttonStyle(.plain).id(line.id).accessibilityIdentifier("lyricLine\(line.id)")
                                            .accessibilityValue(active == line.id ? "Línea actual" : playbackTime(time))
                                    } else { Text(line.text).font(.title3).textSelection(.enabled) }
                                }
                            }.padding(24)
                        }
                        .onChange(of: active) { if autoScroll, let active { withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { reader.scrollTo(active, anchor: .center) } } }
                        .onChange(of: autoScroll) { if autoScroll, let active { withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { reader.scrollTo(active, anchor: .center) } } }
                    }
                    if let source = player.currentDetails?.lyricsSource { Text(source).font(.caption).foregroundStyle(.secondary).padding(8) }
                }
            }
            .background(PlayerTheme(scheme).background)
            .navigationTitle("Letra").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Listo") { dismiss() } }
                ToolbarItem(placement: .primaryAction) { Button("Editar") { editingTrack = player.current }.disabled(player.current == nil) }
            }
            .task(id: player.current?.id) { offset = UserDefaults.standard.double(forKey: "lyricsOffset.\(player.current?.id ?? "")") }
            .onChange(of: offset) { if let id = player.current?.id { UserDefaults.standard.set(offset, forKey: "lyricsOffset.\(id)") } }
            .sheet(item: $editingTrack) { MetadataEditorView(player: player, track: $0) }
        }
    }
}
