import SwiftUI

struct SoundSettingsView: View {
    let player: PlaybackController
    var body: some View {
        List {
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
