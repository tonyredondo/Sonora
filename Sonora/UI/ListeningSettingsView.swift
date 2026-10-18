import SwiftUI

struct ListeningSettingsView: View {
    let player: PlaybackController
    @Environment(\.colorScheme) private var scheme
    @State private var balance = 0.0
    @State private var volumeSelection: VolumeAnalysisSelection?
    private var theme: PlayerTheme { PlayerTheme(scheme) }
    var body: some View {
        Form {
            Section {
                Picker("Igualar volumen", selection: Binding(get: { player.listeningSettings.normalization }, set: { player.setListening(normalization: $0) })) {
                    ForEach(NormalizationMode.allCases) { mode in Text(mode.title).tag(mode) }
                }.accessibilityIdentifier("normalizationMode")
                if player.listeningSettings.normalization != .off, let details = player.currentDetails {
                    Text(details.normalizationGain == 1 ? "Pista actual: volumen original." : String(format: "Pista actual: %+.1f dB", 20 * log10(details.normalizationGain)))
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if !player.queue.tracks.isEmpty {
                    Button("Analizar canciones de la cola", systemImage: "waveform") { volumeSelection = .init(tracks: player.queue.tracks) }
                }
            } header: { Text("Igualar volumen entre canciones") } footer: {
                Text("Usa los análisis guardados en Sonora o las etiquetas ReplayGain del archivo y limita la ganancia según su pico. Por álbum mantiene las diferencias del disco. Sin datos del modo elegido, conserva el volumen original.")
            }
            Section("Balance") {
                HStack { Text("Izquierda"); Spacer(); Text(abs(balance) < 0.01 ? "Centro" : String(format: "%.0f %% %@", abs(balance) * 100, balance < 0 ? "I" : "D")).monospacedDigit(); Spacer(); Text("Derecha") }
                    .font(.caption).foregroundStyle(.secondary)
                MediaSlider(value: $balance, range: -1...1, tint: theme.accent, label: "Balance") { editing in
                    if !editing { player.setListening(balance: Float(balance)) }
                }.frame(height: 44).accessibilityIdentifier("listeningBalance")
                    .accessibilityValue(String(format: "%.0f por ciento %@", abs(balance) * 100, balance < 0 ? "izquierda" : "derecha"))
                    .accessibilityAdjustableAction { direction in
                        balance = min(1, max(-1, balance + (direction == .increment ? 0.1 : -0.1)))
                        player.setListening(balance: Float(balance))
                    }
                Button("Centrar balance") { balance = 0; player.setListening(balance: 0) }
            }

        }
        .scrollContentBackground(.hidden).background(theme.background).tint(theme.accent)
        .navigationTitle("Volumen y balance").navigationBarTitleDisplayMode(.inline)
        .onAppear { balance = Double(player.listeningSettings.balance) }
        .sheet(item: $volumeSelection) { VolumeAnalysisView(player: player, selection: $0) }
    }
}
