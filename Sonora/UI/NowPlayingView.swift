import AVKit
import MediaPlayer
import SwiftUI
import SonoraCore

struct NowPlayingView: View {
    @Bindable var player: PlaybackController
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("showArtworkLyrics") private var showArtworkLyrics = true
    @State private var showQueue = false
    @State private var showLyrics = false
    @State private var lyricsScrollRequest = 0
    @State private var showListening = false
    @State private var showTimer = false
    @State private var songAction: SongActionRequest?
    @GestureState private var downwardDrag: CGFloat = 0
    @State private var completedDrag: CGFloat?
    private var theme: PlayerTheme { PlayerTheme(scheme) }
    private var artworkHasScrollableLyrics: Bool { showArtworkLyrics && player.currentDetails?.lyrics.lines.isEmpty == false }
    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                let compact = geometry.size.height < 700 || dynamicTypeSize.isAccessibilitySize
                VStack(spacing: compact ? 12 : 20) {
                    header.contentShape(.rect).simultaneousGesture(minimizeGesture)
                        .fixedSize(horizontal: false, vertical: true)
                    // Artwork yields its height before text or touch targets are compressed.
                    NowPlayingArtwork(player: player, showsLyrics: showArtworkLyrics, scrollRequest: lyricsScrollRequest) {
                        showLyrics = true
                    }
                        .id(player.current?.id)
                        .aspectRatio(1, contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .layoutPriority(-1)
                        .contentShape(.rect)
                        .simultaneousGesture(minimizeGesture,including:artworkHasScrollableLyrics ? .subviews : .all)
                        .accessibilityElement(children:.contain).accessibilityLabel("Carátula").accessibilityIdentifier("playerArtwork")
                    trackInformation(compact: compact).fixedSize(horizontal: false, vertical: true)
                    PlaybackTimeline(player: player, tint: theme.accent).fixedSize(horizontal: false, vertical: true)
                    transport.fixedSize(horizontal: false, vertical: true)
                    output.fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, compact ? 20 : 28)
                .padding(.vertical, compact ? 8 : 12)
                .frame(width: geometry.size.width, height: geometry.size.height)
                .offset(y:completedDrag ?? downwardDrag)
                .animation(downwardDrag == 0 && completedDrag == nil && !reduceMotion ? .spring(response:0.3,dampingFraction:0.85) : nil,value:downwardDrag)
            }.background(theme.background).toolbar(.hidden, for: .navigationBar)
        }.tint(theme.accent).sheet(isPresented: $showQueue) { QueueView(player: player) }
            .sheet(isPresented: $showLyrics, onDismiss: { lyricsScrollRequest += 1 }) { LyricsView(player: player) }
            .sheet(item: $songAction) { SongActionSheet(player: player, request: $0) }
            .sheet(isPresented: $showListening) {
                NavigationStack { SoundSettingsView(player: player).toolbar { ToolbarItem(placement: .confirmationAction) { Button("Listo") { showListening = false } } } }
            }
            .sheet(isPresented: $showTimer) {
                NavigationStack { SleepTimerView(player: player).toolbar { ToolbarItem(placement: .confirmationAction) { Button("Listo") { showTimer = false } } } }
            }
    }
    private var minimizeGesture: some Gesture {
        DragGesture(minimumDistance:18,coordinateSpace:.global)
            .updating($downwardDrag) { value,offset,_ in
                let distance = value.translation.height
                offset = distance > abs(value.translation.width) * 1.25 ? max(0,distance) : 0
            }
            .onEnded { value in
                let distance = value.translation.height
                guard distance > abs(value.translation.width) * 1.25,
                      distance > 120 || distance > 45 && value.predictedEndTranslation.height > 240 else { return }
                // Keep the released position while the full-screen cover dismisses.
                completedDrag = max(0,distance)
                dismiss()
            }
    }
    private var header: some View {
        HStack {
            Button { dismiss() } label: { Image(systemName: "chevron.down").frame(width: 44, height: 44) }.accessibilityLabel("Cerrar reproductor")
            Spacer(minLength: 8)
            Text(player.currentDetails?.album ?? player.folderName).font(.subheadline).lineLimit(1)
            Spacer(minLength: 8)
            Button { showArtworkLyrics.toggle() } label: {
                Image(systemName: showArtworkLyrics ? "quote.bubble.fill" : "quote.bubble")
                    .frame(width: 44, height: 44)
            }
            .foregroundStyle(showArtworkLyrics ? theme.accent : .secondary)
            .accessibilityLabel(showArtworkLyrics ? "Ocultar letra en portada" : "Mostrar letra en portada")
            .accessibilityValue(showArtworkLyrics ? "Visibles" : "Ocultas")
            .accessibilityAddTraits(showArtworkLyrics ? .isSelected : [])
            .accessibilityIdentifier("toggleArtworkLyrics")
            Menu {
                Button("Sonido", systemImage: "slider.horizontal.3") { showListening = true }
                Button("Temporizador", systemImage: "moon.zzz") { showTimer = true }
                Divider()
                if let track = player.current { SongActions(player: player, track: track) { songAction = $0 } }
            } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }.accessibilityLabel("Opciones de canción")
            Button { showQueue = true } label: { Image(systemName: "list.bullet").frame(width: 44, height: 44) }.accessibilityLabel("Cola").accessibilityIdentifier("playerQueue")
        }.font(.system(size: 18, weight: .medium))
    }
    private func trackInformation(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: compact ? 4 : 8) {
            Text(player.currentDetails?.title ?? player.current?.displayName ?? "Sonora")
                .font(.system(compact ? .title3 : .title, design: theme.heading, weight: .bold))
                .lineLimit(compact ? 1 : 2).textSelection(.enabled).accessibilityIdentifier("playerTitle")
            Text(player.currentDetails?.artist ?? "Artista desconocido")
                .font(compact ? .subheadline : .title3).foregroundStyle(.secondary).lineLimit(1)
            if let format = player.currentDetails?.format {
                Text(format).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private var transport: some View {
        HStack(spacing: 16) {
            Button { player.shuffle.toggle() } label: { Image(systemName: "shuffle").frame(width: 44, height: 44) }
                .foregroundStyle(player.shuffle ? theme.accent : .secondary).accessibilityLabel("Aleatorio").accessibilityValue(player.shuffle ? "Activado" : "Desactivado")
            Button { player.previous() } label: { Image(systemName: "backward.end.fill").font(.system(size: 28)).frame(width: 44, height: 44) }.accessibilityLabel("Anterior")
            playButton
            Button { player.next() } label: { Image(systemName: "forward.end.fill").font(.system(size: 28)).frame(width: 44, height: 44) }.accessibilityLabel("Siguiente")
            Button {
                player.repeatMode = player.repeatMode == .off ? .all : player.repeatMode == .all ? .one : .off
            } label: { Image(systemName: player.repeatMode == .one ? "repeat.1" : "repeat").frame(width: 44, height: 44) }
                .foregroundStyle(player.repeatMode == .off ? .secondary : theme.accent)
                .accessibilityLabel("Repetición").accessibilityValue(player.repeatMode == .off ? "Desactivada" : player.repeatMode == .one ? "Una canción" : "Toda la cola")
        }.font(.system(size: 20))
    }
    private var output: some View {
        HStack(spacing: 12) {
            Image(systemName: "speaker.wave.2.fill").accessibilityHidden(true)
            SystemVolumeControl(tint: theme.accent)
                .frame(maxWidth: .infinity).frame(height: 44)
                .accessibilityIdentifier("playerVolume")
            AudioRoutePicker().frame(width: 44, height: 44).accessibilityLabel("Elegir salida de audio").accessibilityIdentifier("playerOutput")
        }.font(.system(size: 18)).foregroundStyle(.secondary)
    }
    private var playButton: some View {
        Button { player.togglePlayback() } label: {
            ZStack {
                Circle().strokeBorder(.primary.opacity(0.6), lineWidth: 1).frame(width: 76, height: 76)
                if player.isPreparing { ProgressView() }
                else { Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 30)).contentTransition(.symbolEffect(.replace)) }
            }
        }.accessibilityLabel(player.isPlaying ? "Pausar" : "Reproducir").accessibilityIdentifier("playerTransport")
    }
}

struct PlaybackTimeline: View {
    let player: PlaybackController
    let tint: Color
    @State private var scrubbing = false
    @State private var position: Double = 0
    var body: some View {
        VStack(spacing: 5) {
            MediaSlider(value: Binding(get: { scrubbing ? position : min(player.currentTime, max(player.duration, 1)) }, set: { position = $0 }),
                   range: 0...max(player.duration, 1), tint: tint, label: "Posición de reproducción", onEditingChanged: { editing in
                scrubbing = editing
                if !editing { player.seek(to: position) }
            }).frame(height: 44).disabled(player.duration <= 0)
            HStack {
                Text(playbackTime(scrubbing ? position : player.currentTime)).accessibilityIdentifier("playerElapsedTime")
                Spacer(); Text(playbackTime(player.duration))
            }.font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
    }
}

struct MiniPlayer: View {
    let player: PlaybackController
    let openPlayer: () -> Void
    let openQueue: () -> Void
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        ZStack(alignment: .trailing) {
            Button(action: openPlayer) {
                HStack(spacing: 12) {
                    ArtworkView(image: player.currentDetails?.artwork, cornerRadius: 6).frame(width: 46, height: 46)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(player.currentDetails?.title ?? player.current?.displayName ?? "Sonora").font(.subheadline.weight(.medium)).lineLimit(1)
                        Text(player.currentDetails?.artist ?? "Artista desconocido").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.trailing, 108) // Two 44-point controls and their 10-point gaps.
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
            }.buttonStyle(.plain).accessibilityHint("Abrir reproductor").accessibilityIdentifier("openNowPlaying")
            HStack(spacing: 10) {
                Button { player.togglePlayback() } label: {
                    if player.isPreparing { ProgressView().frame(width: 44, height: 44) }
                    else { Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.title3).frame(width: 44, height: 44) }
                }.accessibilityLabel(player.isPlaying ? "Pausar" : "Reproducir").accessibilityIdentifier("miniTransport")
                Button(action: openQueue) { Image(systemName: "list.bullet").frame(width: 44, height: 44) }.accessibilityLabel("Cola").accessibilityIdentifier("miniQueue")
            }.padding(.trailing, 12)
        }.background(PlayerTheme(scheme).surface).clipShape(.rect(cornerRadius: 14)).padding(.horizontal, 12).padding(.bottom, 6)
    }
}

private struct AudioRoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView { let view = AVRoutePickerView(); view.prioritizesVideoDevices = false; return view }
    func updateUIView(_ view: AVRoutePickerView, context: Context) { }
}

private struct SystemVolumeControl: UIViewRepresentable {
    let tint: Color

    func makeUIView(context: Context) -> VolumeControlView { VolumeControlView() }

    func updateUIView(_ view: VolumeControlView, context: Context) {
        view.volumeView.tintColor = UIColor(tint)
    }
}

private final class VolumeControlView: UIView {
    let volumeView = MPVolumeView(frame: CGRect(x: 0, y: 0, width: 1, height: 44))

    init() {
        super.init(frame: .zero)
        configureVolumeView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureVolumeView()
    }

    private func configureVolumeView() {
        // Apple still uses this property to hide the legacy button; routing uses AVRoutePickerView.
        volumeView.showsRouteButton = false
        for state: UIControl.State in [.normal, .highlighted, .disabled] {
            volumeView.setVolumeThumbImage(MediaSliderImages.invisibleThumb, for: state)
        }
        addSubview(volumeView)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        volumeView.frame = bounds
        volumeView.layoutIfNeeded()
        let slider = volumeView.volumeSliderRect(forBounds: volumeView.bounds)
        if !slider.isEmpty {
            // MPVolumeView's slider need not be centered in its own bounds.
            volumeView.frame.origin.y += bounds.midY - slider.midY
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else { return }
        // MPVolumeView creates its slider when attached to a window. Recenter after that setup.
        DispatchQueue.main.async { [weak self] in self?.setNeedsLayout() }
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard isUserInteractionEnabled, !isHidden, alpha > 0.01, bounds.contains(point) else { return nil }
        let nativePoint = convert(point, to: volumeView)
        if let hit = volumeView.hitTest(nativePoint, with: event), hit !== volumeView { return hit }
        // Preserve the full 44pt touch area around the centered native slider.
        let slider = volumeView.volumeSliderRect(forBounds: volumeView.bounds)
        guard !slider.isEmpty else { return nil }
        return volumeView.hitTest(CGPoint(x: nativePoint.x, y: slider.midY), with: event)
    }
}
