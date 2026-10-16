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
                    NavigationLink("Ecualizador") { EqualizerView(player: player) }
                    NavigationLink("Entre canciones") { TransitionSettingsView(player: player) }
                    NavigationLink("Escucha") { ListeningSettingsView(player: player) }
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
