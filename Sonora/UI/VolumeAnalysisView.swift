import SwiftUI

struct VolumeAnalysisView: View {
    let player: PlaybackController
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @Environment(\.scenePhase) private var scenePhase
    @State private var session: VolumeAnalysisSession
    @State private var confirmSave = false
    @State private var confirmReset = false
    private var theme: PlayerTheme { PlayerTheme(scheme) }

    init(player: PlaybackController, selection: VolumeAnalysisSelection) {
        self.player = player
        _session = State(initialValue: VolumeAnalysisSession(player: player, selection: selection))
    }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label(session.selection.album ? "Álbum completo" : "Por canción", systemImage: "waveform.path")
                        .font(.headline)
                    Text(session.selection.tracks.count == 1 ? "1 canción seleccionada" : "\(session.selection.tracks.count) canciones seleccionadas")
                    Text("Calcula el ajuste de ReplayGain y lo guarda en Sonora.")
                        .font(.footnote).foregroundStyle(.secondary)
                } footer: { Text("iCloud requiere descargar los archivos. El análisis se detiene al cerrar esta pantalla o salir de la app.") }

                Section {
                    if session.isLoading || session.isWorking {
                        Text(session.status).font(.headline).accessibilityIdentifier("volumeStatus")
                    }
                    if session.isLoading { ProgressView("Buscando resultados guardados…") }
                    else if session.isWorking {
                        ProgressView(value: session.progress) {
                            Text(session.isSaving ? "Guardando · \(session.completedCount) / \(session.saveTargetCount)" : "\(session.completedCount) / \(session.targets.count) canciones")
                        }.accessibilityLabel("Progreso del análisis")
                        if !session.currentFilename.isEmpty { Text(session.currentFilename).font(.caption).foregroundStyle(.secondary) }
                        Button(session.isSaving ? "Cancelar guardado" : "Cancelar análisis", role: .cancel) { session.cancel() }
                            .disabled(session.cancellationRequested)
                    } else {
                        CompactActionHeader {
                            Text(session.status).font(.headline).accessibilityIdentifier("volumeStatus")
                        } actions: {
                            CompactActionRow(layout: .inline) {
                                Button { session.start() } label: {
                                    CompactActionLabel(title: "Analizar", icon: "waveform")
                                }.accessibilityIdentifier("volumeAnalyze")
                                    .disabled(session.targets.isEmpty || player.volumeAnalysis.issue != nil)
                                if !session.results.isEmpty {
                                    Button { session.start(force: true) } label: {
                                        CompactActionLabel(title: "Volver a analizar todos", icon: "arrow.clockwise", caption: "Reanalizar")
                                    }.disabled(player.volumeAnalysis.issue != nil)
                                }
                            }
                        }
                    }
                    if session.analyzedCount + session.reusedCount > 0 {
                        Text("Analizados \(session.analyzedCount) · Reutilizados \(session.reusedCount)")
                            .font(.footnote).foregroundStyle(.secondary).accessibilityIdentifier("volumeSummary")
                    }
                } footer: { Text("Se reutilizan los análisis de archivos sin cambios.") }

                if let result = session.saveResult {
                    Section("Etiquetas guardadas") {
                        Text("Guardados \(result.written) de \(session.saveTargetCount)").accessibilityIdentifier("volumeSaveResult")
                        ForEach(result.failures) { failure in failureRow(failure) }
                    }
                }
                if let album = session.albumResult {
                    Section("Resultado del álbum") {
                        Text(String(format: "Ajuste conjunto: %+.2f dB", album.gain)).accessibilityIdentifier("volumeAlbumGain")
                        Text("Mantiene las diferencias de volumen entre sus canciones.").font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Section {
                    ForEach(session.targets, id: \.id) { target in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(player.library.state.songs[target.id]?.title ?? target.url.lastPathComponent).font(.body.weight(.medium))
                            Text(target.url.lastPathComponent).font(.caption).foregroundStyle(.secondary)
                            if let value = session.results[target.id] {
                                Text(String(format: "%+.2f dB · Pico %.1f %%", value.gain, value.peak * 100))
                                    .monospacedDigit()
                                if target.cue != nil || !MetadataService.writableExtensions.contains(target.url.pathExtension.lowercased()) {
                                    Text("Resultado guardado solo en Sonora").font(.caption).foregroundStyle(.secondary)
                                }
                            } else { Text("Pendiente de análisis").font(.caption).foregroundStyle(.secondary) }
                        }.padding(.vertical, 3).accessibilityElement(children: .combine)
                            .accessibilityIdentifier((session.results[target.id] == nil ? "volume-pending:" : "volume-result:") + (player.library.state.songs[target.id]?.relativePath ?? target.url.lastPathComponent))
                    }
                } header: { Text("Canciones") } footer: { Text("Activa ReplayGain en Ajustes → Escucha para aplicar estos resultados. El audio original se conserva.") }
                if !session.saveableTargets.isEmpty {
                    Section {
                        Button("Guardar etiquetas…", systemImage: "square.and.arrow.down") { confirmSave = true }
                            .disabled(session.isWorking || session.isLoading || player.volumeAnalysis.issue != nil)
                        Text(session.saveableTargets.count == 1 ? "1 archivo compatible. Las etiquetas permiten usar este ajuste en otros reproductores." : "\(session.saveableTargets.count) archivos compatibles. Las etiquetas permiten usar estos ajustes en otros reproductores.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if !session.failures.isEmpty { Section("Archivos sin analizar") { ForEach(session.failures) { failureRow($0) } } }
                if let issue = session.issue { Section { Text(issue).foregroundStyle(.red) } }
                if let issue = player.volumeAnalysis.issue {
                    Section {
                        Text(issue)
                        Button("Restablecer análisis", role: .destructive) { confirmReset = true }
                    }
                }
            }
            .scrollContentBackground(.hidden).background(theme.background).tint(theme.accent)
            .compactContentSpacing()
            .navigationTitle("Analizar volumen").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Listo") { session.cancel(); dismiss() } } }
            .confirmationDialog("Guardar etiquetas ReplayGain", isPresented: $confirmSave, titleVisibility: .visible) {
                Button("Guardar en los archivos") { session.saveTags() }
            } message: { Text("Se añadirán o actualizarán las etiquetas de volumen en \(session.saveableTargets.count) archivos. Se conservarán el audio y los demás metadatos.") }
            .confirmationDialog("¿Restablecer los análisis guardados?", isPresented: $confirmReset, titleVisibility: .visible) {
                Button("Restablecer análisis", role: .destructive) { session.resetSavedAnalysis() }
            } message: { Text("Se borrarán únicamente los resultados locales. Los archivos de música conservarán sus etiquetas.") }
            .task { await session.load() }
            .onDisappear { session.cancel() }
            .onChange(of: scenePhase) { _, phase in if phase == .background { session.cancel() } }
        }
    }
    private func failureRow(_ failure: MetadataWriteFailure) -> some View {
        VStack(alignment: .leading, spacing: 4) { Text(failure.filename); Text(failure.message).font(.caption).foregroundStyle(.secondary) }
    }
}
