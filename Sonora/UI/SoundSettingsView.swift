import SwiftUI

struct SoundSettingsView: View {
    let player: PlaybackController
    var body: some View {
        List {
            PlaybackAdjustmentControls(player: player)
            if let track = player.current {
                Section {
                    NavigationLink { SongAnalysisView(player: player, track: track) } label: { Label("BPM, forma de onda y marcadores", systemImage: "waveform.path") }
                        .accessibilityIdentifier("openSongAnalysis")
                    NavigationLink { AudioCharacterView(player: player) } label: { Label("Estilo y ambiente", systemImage: "music.note") }
                        .accessibilityIdentifier("openAudioCharacterDetail")
                    Button("Actualizar análisis", systemImage: "arrow.clockwise") { player.refreshCurrentSongMetadata() }
                        .disabled(player.songMetadataRefresh?.isRunning == true || player.isPreparing || player.isLoading)
                        .accessibilityIdentifier("refreshSongMetadata")
                } header: { Text("Canción actual") } footer: {
                    Text("Recalcula BPM, onda, estilo y ambiente y renueva traducción y significado. Conserva tus marcadores y correcciones. Estilo y ambiente requieren tu servidor; traducción y significado usan Codex.")
                }
            }
            if let refresh = player.songMetadataRefresh {
                Section {
                    ForEach(SongMetadataRefresh.Step.allCases) { step in
                        SongRefreshStatusRow(step: step, status: refresh.steps[step] ?? .waiting)
                    }
                } header: {
                    Text(refresh.isRunning ? "Actualizando · \(refresh.title)" : "Resultado · \(refresh.title)")
                }
            }
            Section {
                NavigationLink { EqualizerView(player: player) } label: { Label("Ecualizador", systemImage: "slider.vertical.3") }
                NavigationLink { TransitionSettingsView(player: player) } label: { Label("Transiciones entre canciones", systemImage: "arrow.triangle.branch") }
                NavigationLink { ListeningSettingsView(player: player) } label: { Label("Igualar volumen y balance", systemImage: "speaker.wave.2") }
            }
            Section {
                NavigationLink { SleepTimerView(player: player) } label: { Label("Temporizador", systemImage: "moon.zzz") }
            }
        }.navigationTitle("Sonido").navigationBarTitleDisplayMode(.inline)
    }
}

private struct SongRefreshStatusRow: View {
    let step: SongMetadataRefresh.Step
    let status: SongMetadataRefresh.Status
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            switch status {
            case .waiting:
                Label(step.title + " · En espera", systemImage: "clock").foregroundStyle(.secondary)
            case .running:
                HStack(spacing: 10) { ProgressView(); Text(step.title + " · Actualizando…") }
            case .updated:
                Label(step.title + " · Actualizado", systemImage: "checkmark.circle")
            case .skipped(let reason):
                Label(step.title, systemImage: "info.circle")
                Text(reason).font(.footnote).foregroundStyle(.secondary)
            case .failed(let message):
                Label(step.title + " · No se pudo actualizar", systemImage: "exclamationmark.circle").foregroundStyle(.red)
                Text(message).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("refreshSongMetadata.\(step.rawValue)")
    }
}

struct SleepTimerView: View {
    let player: PlaybackController
    var body: some View {
        Form {
            Section {
                if let timer = player.sleepTimer {
                    switch timer {
                    case .deadline(let date): HStack { Text("Pausa dentro de"); Spacer(); Text(date, style: .timer).monospacedDigit() }.accessibilityIdentifier("sleepStatus")
                    case .endOfTrack: Text("Al terminar esta canción").accessibilityIdentifier("sleepStatus")
                    }
                    Button("Cancelar temporizador", role: .destructive) { player.setSleepTimer(nil) }
                } else { Text("Desactivado").foregroundStyle(.secondary) }
                Menu {
                    ForEach([15, 30, 45, 60, 90], id: \.self) { minutes in
                        Button("\(minutes) minutos") { player.setSleepTimer(.deadline(Date().addingTimeInterval(Double(minutes) * 60))) }
                    }
                } label: {
                    HStack {
                        Text("Pausar después de…")
                        Spacer()
                        Image(systemName: "chevron.up.chevron.down").font(.caption).accessibilityHidden(true)
                    }.frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
                }
                Button("Al terminar esta canción") { if let track = player.current { player.setSleepTimer(.endOfTrack(track.id)) } }.disabled(player.current == nil)
            } header: { Text("Temporizador") } footer: { Text("Al terminar la canción se conserva su final completo y se pausa antes de la siguiente, incluso con Crossfade activado. Cambiar de canción cancela esa opción.") }
        }.navigationTitle("Temporizador").navigationBarTitleDisplayMode(.inline)
    }
}
