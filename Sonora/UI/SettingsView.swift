import SwiftUI

struct SettingsView: View {
    let player: PlaybackController
    @AppStorage("appearance") private var appearance: AppAppearance = .noche
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Apariencia") {
                    Picker("Apariencia", selection: $appearance) {
                        ForEach(AppAppearance.allCases) { item in Text(item.title).tag(item) }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
                Section("Reproducción") {
                    NavigationLink("Sonido") { SoundSettingsView(player: player) }
                    NavigationLink("Temporizador") { SleepTimerView(player: player) }
                }
                Section("Tu música") {
                    NavigationLink("Preparación automática") { QueuePreparationSettingsView(player: player) }
                        .accessibilityIdentifier("queuePreparationSettings")
                    NavigationLink("Servicios online y copias de información") { MetadataConnectionView() }
                        .accessibilityIdentifier("metadataAssistantSettings")
                }
                Section {
                    Text("La música se reproduce desde sus carpetas. El editor de información guarda los cambios en el archivo original cuando pulsas Guardar.")
                        .foregroundStyle(.secondary)
                }
                Section("Acerca de Sonora") {
                    LabeledContent("Versión", value: "0.1.0")
                    NavigationLink("Licencias de audio") {
                        ScrollView {
                            Text(notices).font(.caption.monospaced()).textSelection(.enabled).padding()
                        }.navigationTitle("Licencias")
                    }
                }
            }
            .navigationTitle("Ajustes")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Listo") { dismiss() } } }
        }
        .preferredColorScheme(appearance.colorScheme)
    }

    private var notices: String {
        guard let url = Bundle.main.url(forResource: "ThirdPartyNotices", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return "SFBAudioEngine: https://github.com/sbooth/SFBAudioEngine"
        }
        return text
    }
}

struct QueuePreparationSettingsView: View {
    let player: PlaybackController
    @AppStorage("prepareQueueAudio") private var audio = true
    @AppStorage("prepareQueueTranslation") private var translation = true
    @AppStorage("prepareQueueMeaning") private var meaning = true

    var body: some View {
        Form {
            Section {
                Toggle("BPM y forma de onda", isOn: $audio).accessibilityIdentifier("prepareQueueAudio")
                Toggle("Traducción", isOn: $translation).accessibilityIdentifier("prepareQueueTranslation")
                Toggle("Significado con IA", isOn: $meaning).accessibilityIdentifier("prepareQueueMeaning")
            } header: { Text("Toda la cola de reproducción") } footer: {
                Text("Damos prioridad a la canción actual y preparamos las demás una a una. Los resultados se guardan para reutilizarlos. Al desactivar una función, termina el análisis que ya haya empezado.")
            }
            Section {
                Text("Significado envía la letra a Codex a través de tu servidor y consume uso de tu plan solo cuando falta un resultado guardado. La traducción necesita tener descargados los idiomas elegidos.")
                    .font(.footnote).foregroundStyle(.secondary)
                Text("La preparación avanza mientras iOS permite ejecutar Sonora. Si el sistema suspende la app, continúa al volver a abrirla.")
                    .font(.footnote).foregroundStyle(.secondary)
                if player.queuePreparation.isRunning {
                    ProgressView("Preparando canciones · \(player.queuePreparation.pendingCount) pendientes")
                }
                if meaning && player.lyricInterpretations.pendingCount > 0 {
                    Text("Significados pendientes: \(player.lyricInterpretations.pendingCount)")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if let issue = player.lyricInterpretations.automaticIssue {
                    Text("Significado en pausa: \(issue)").foregroundStyle(.secondary)
                } else if meaning && player.lyricInterpretations.waitingForConnection {
                    Text("Significado pendiente de conexión con el servidor.").foregroundStyle(.secondary)
                }
                ForEach(player.queuePreparation.issues.sorted(by: { $0.key < $1.key }), id: \.key) { issue in
                    Text(issue.value).font(.footnote).foregroundStyle(.red)
                }
                Button("Reintentar pendientes", systemImage: "arrow.clockwise") { player.retryQueuePreparation() }
                    .disabled(player.queue.tracks.isEmpty).accessibilityIdentifier("retryQueuePreparation")
            }
        }
        .navigationTitle("Preparación automática").navigationBarTitleDisplayMode(.inline)
    }
}
