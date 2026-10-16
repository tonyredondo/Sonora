import SwiftUI

struct EqualizerView: View {
    let player: PlaybackController
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dynamicTypeSize) private var typeSize
    private var equalizer: AudioEqualizer { player.equalizer }
    private var theme: PlayerTheme { PlayerTheme(scheme) }
    private var highestFrequency: Float { Float((player.currentDetails?.sampleRate ?? 48000) / 2) }

    var body: some View {
        Form {
            Section {
                Toggle("Activar ecualizador", isOn: Binding(get: { equalizer.settings.enabled }, set: { equalizer.setEnabled($0) }))
                    .accessibilityIdentifier("equalizerEnabled")
            } footer: {
                Text("Al desactivarlo escuchas el sonido original y conservas tus ajustes.")
            }
            Section {
                Menu {
                    ForEach(EqualizerPreset.allCases) { preset in
                        Button(preset.title) { equalizer.select(preset) }
                    }
                } label: {
                    HStack {
                        Text("Preajuste").foregroundStyle(.primary)
                        Spacer()
                        Text(equalizer.preset?.title ?? "Personalizado").accessibilityIdentifier("equalizerPresetName")
                        Image(systemName: "chevron.up.chevron.down").font(.caption).accessibilityHidden(true)
                    }
                }.accessibilityIdentifier("equalizerPreset")
            }
            Section("Bandas") {
                if typeSize.isAccessibilitySize {
                    ForEach(EqualizerSettings.frequencies.indices, id: \.self) { index in
                        VStack(alignment: .leading, spacing: 2) {
                            valueHeader(frequency(index), value: gain(equalizer.settings.gains[index]))
                                .accessibilityHidden(true)
                            band(index)
                        }
                    }
                } else {
                    VStack(spacing: 20) {
                        bandGroup(0..<5)
                        bandGroup(5..<10)
                    }.padding(.vertical, 6)
                }
            }.disabled(!equalizer.settings.enabled)
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    valueHeader("Preamplificación", value: gain(equalizer.settings.preamp))
                    MediaSlider(value: Binding(get: { Double(equalizer.settings.preamp) }, set: { equalizer.setPreamp(Float($0)) }),
                                range: -24...12, tint: theme.accent, label: "Preamplificación")
                        .frame(height: 44).accessibilityValue(gain(equalizer.settings.preamp)).accessibilityIdentifier("eqPreamp")
                }
            } footer: {
                Text("Si el sonido satura al realzar bandas, baja la preamplificación. Las frecuencias que no contiene el archivo quedan desactivadas.")
            }.disabled(!equalizer.settings.enabled)
            Section {
                Button("Restablecer a plano") { equalizer.select(.flat) }
            }
        }
        .scrollContentBackground(.hidden).background(theme.background).tint(theme.accent)
        .navigationTitle("Ecualizador").navigationBarTitleDisplayMode(.inline)
    }

    private func frequency(_ index: Int) -> String {
        let value = EqualizerSettings.frequencies[index]
        return value < 1000 ? String(format: "%.0f Hz", value) : String(format: "%.0f kHz", value / 1000)
    }
    private func gain(_ value: Float) -> String { String(format: "%+.1f dB", value) }
    @ViewBuilder private func valueHeader(_ title: String, value: String) -> some View {
        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 4) { Text(title); Text(value).monospacedDigit() }
        } else {
            HStack { Text(title); Spacer(); Text(value).monospacedDigit() }
        }
    }
    private func band(_ index: Int) -> some View {
        MediaSlider(value: Binding(get: { Double(equalizer.settings.gains[index]) }, set: { equalizer.setGain(index, to: Float($0)) }),
                    range: -12...12, tint: theme.accent, label: frequency(index))
            .frame(height: 44)
            .disabled(EqualizerSettings.frequencies[index] >= highestFrequency)
            .accessibilityValue(gain(equalizer.settings.gains[index]))
            .accessibilityIdentifier("eqBand\(index)")
            .accessibilityAdjustableAction { direction in
                let step: Float = direction == .increment ? 0.5 : -0.5
                equalizer.setGain(index, to: equalizer.settings.gains[index] + step)
            }
    }
    private func bandGroup(_ indices: Range<Int>) -> some View {
        HStack(spacing: 6) {
            ForEach(indices, id: \.self) { index in
                VStack(spacing: 4) {
                    Text(gain(equalizer.settings.gains[index])).font(.caption2.monospacedDigit()).accessibilityHidden(true)
                    band(index).frame(width: 110, height: 44).rotationEffect(.degrees(-90)).frame(width: 44, height: 112)
                    Text(frequency(index)).font(.caption2).accessibilityHidden(true)
                }.frame(maxWidth: .infinity)
            }
        }
    }
}
