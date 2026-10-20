import SwiftUI

struct TransitionSettingsView: View {
    let player: PlaybackController
    @Environment(\.colorScheme) private var scheme
    @State private var duration = 5.0
    private var theme: PlayerTheme { PlayerTheme(scheme) }

    var body: some View {
        Form {
            Section {
                Picker("Entre canciones", selection: Binding(get: { player.transitionSettings.mode }, set: { player.setTransition(mode: $0) })) {
                    ForEach(TransitionMode.allCases) { mode in Text(mode.title).tag(mode) }
                }.pickerStyle(.inline)
            } footer: {
                Text("Continua conserva el final de cada canción, sin superponerlas. Es la opción recomendada para conciertos y discos en directo.")
            }
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text(player.transitionSettings.mode == .adaptive ? "Duración máxima de la mezcla" : "Duración del fundido")
                    Text(String(format: "%.0f s", duration)).foregroundStyle(theme.accent).monospacedDigit()
                        .accessibilityIdentifier("crossfadeDurationValue")
                    MediaSlider(value: $duration, range: 1...12, tint: theme.accent, label: "Duración del fundido") { editing in
                        if !editing { player.setTransition(duration: duration); duration = player.transitionSettings.duration }
                    }
                    .frame(height: 44)
                    .accessibilityValue(String(format: "%.0f segundos", duration))
                    .accessibilityIdentifier("crossfadeDuration")
                    .accessibilityAdjustableAction { direction in
                        player.setTransition(duration: duration + (direction == .increment ? 1 : -1))
                        duration = player.transitionSettings.duration
                    }
                }
            } footer: {
                Text("Crossfade baja el volumen de la canción que termina mientras entra la siguiente. En pistas cortas se limita a la mitad de la más breve. Si la siguiente no está preparada, la reproducción continúa sin fundido. El fundido se mezcla en estéreo a 48 kHz; los archivos originales se conservan.")
            }.disabled(player.transitionSettings.mode == .continuous)
            if player.transitionSettings.mode == .adaptive {
                Section("Mezcla automática · beta") {
                    Text("Analiza el principio y el final para alinear los golpes, también con un BPM estimado. Si los tempos difieren un poco, acorta la mezcla para mantenerlos próximos. Puede adelantar hasta un segundo el comienzo de la siguiente canción.")
                    Text("Si no puede situar los golpes, usa el BPM estimado para ajustar el fundido. Si no detecta ritmo, usa Crossfade. No cambia la velocidad ni el tono. Para conciertos, elige Continua.")
                        .foregroundStyle(.secondary)
                }
            }
            if let result = player.lastTransition {
                Section("Última transición") { Text(result.description) }
            }
        }
        .scrollContentBackground(.hidden).background(theme.background).tint(theme.accent)
        .navigationTitle("Entre canciones").navigationBarTitleDisplayMode(.inline)
        .onAppear { duration = player.transitionSettings.duration }
    }
}
