import SonoraCore
import SwiftUI

enum AudioCharacterLabels {
    static func style(_ label: String) -> String {
        let name = label.components(separatedBy: "---").last ?? label
        switch name {
        case "Alternative Rock": return "Rock alternativo"
        case "Indie Rock": return "Indie rock"
        case "Brit Pop": return "Britpop"
        case "Pop Rock": return "Pop rock"
        case "Hard Rock": return "Hard rock"
        case "Electronic": return "Electrónica"
        case "Classical": return "Clásica"
        default: return name
        }
    }
    static func mood(_ name: String) -> String {
        switch name {
        case "happy": "Alegre"
        case "sad": "Triste"
        case "relaxed": "Relajada"
        case "aggressive": "Agresiva"
        default: name
        }
    }
}

struct AudioCharacterTags: View {
    let result: AudioCharacter?
    let status: AudioCharacterStore.Status?
    let open: () -> Void
    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                if let result, !result.silent {
                    ForEach(Array(result.styles.prefix(2)), id: \.label) { style in
                        chip(AudioCharacterLabels.style(style.label), id: "songStyle:" + style.label)
                    }
                    ForEach(result.prominentMoods, id: \.self) { mood in
                        chip(AudioCharacterLabels.mood(mood), id: "songMood:" + mood)
                    }
                } else {
                    Button(action: open) {
                        HStack(spacing: 6) {
                            if status == .preparing { ProgressView().controlSize(.mini) }
                            Text(status == .preparing ? "Analizando estilo…" : result?.silent == true ? "Muestra sin sonido" : "Estilo y ambiente")
                        }.font(.caption).foregroundStyle(.secondary).frame(minHeight: 44)
                    }.buttonStyle(.plain).accessibilityIdentifier("openAudioCharacter")
                }
            }
        }.scrollIndicators(.hidden)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("songCharacterTags")
    }
    private func chip(_ text: String, id: String) -> some View {
        Button(action: open) {
            Text(text).font(.caption).foregroundStyle(.primary).lineLimit(1).fixedSize()
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(.primary.opacity(0.07), in: Capsule())
                .overlay { Capsule().strokeBorder(.primary.opacity(0.16), lineWidth: 0.5) }
                .frame(minHeight: 44).contentShape(.rect)
        }.buttonStyle(.plain).accessibilityHint("Ver estilo y ambiente")
            .accessibilityIdentifier(id)
    }
}

struct AudioCharacterView: View {
    let player: PlaybackController
    private var busy: Bool { player.currentCharacterStatus == .preparing }
    var body: some View {
        List {
            if let result = player.currentAudioCharacter {
                if result.silent {
                    Section { Text("Las muestras analizadas no contienen sonido suficiente para identificar un estilo.") }
                } else {
                    Section("Estilos más afines") {
                        ForEach(result.styles, id: \.label) { style in
                            Text(AudioCharacterLabels.style(style.label))
                        }
                    }
                    Section("Ambiente") {
                        ForEach(["happy", "sad", "relaxed", "aggressive"], id: \.self) { mood in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(AudioCharacterLabels.mood(mood))
                                ProgressView(value: result.moods[mood] ?? 0)
                                    .accessibilityLabel(AudioCharacterLabels.mood(mood))
                                    .accessibilityValue((result.moods[mood] ?? 0) >= 0.6 ? "Afinidad alta" : "Afinidad baja")
                            }
                        }
                    }
                }
            }
            Section {
                if busy { ProgressView("Analizando estilo y ambiente…") }
                else if case .failed(let message) = player.currentCharacterStatus { Text(message).foregroundStyle(.secondary) }
                else if player.currentAudioCharacter == nil { Text("El análisis está pendiente de conexión con tu servidor.").foregroundStyle(.secondary) }
                Button(player.currentAudioCharacter == nil ? "Reintentar análisis" : "Actualizar estilo y ambiente", systemImage: "arrow.clockwise") {
                    Task { try? await player.loadCurrentAudioCharacter(refresh: true) }
                }.disabled(busy || player.current == nil).accessibilityIdentifier("refreshAudioCharacter")
            } footer: {
                Text("Essentia analiza fragmentos del audio en tu Mac. Los estilos y el ambiente son estimaciones independientes, no porcentajes de acierto. Los resultados guardados funcionan sin conexión.")
            }
        }.navigationTitle("Estilo y ambiente").navigationBarTitleDisplayMode(.inline)
            .task(id: player.current?.id) { try? await player.loadCurrentAudioCharacter() }
    }
}
