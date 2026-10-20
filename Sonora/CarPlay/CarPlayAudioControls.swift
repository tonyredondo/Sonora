import CarPlay
import SonoraCore

extension CarPlayCoordinator {
    func showAudio() {
        present(list("Audio") { [weak self] in self?.audioRows() ?? [] })
    }

    private var rateText: String { self.player.equalizer.playback.rate.formatted(.number.precision(.fractionLength(0...2))) + "×" }
    private var pitchText: String {
        let value = Int(self.player.equalizer.playback.semitones)
        return value == 0 ? "Tono original" : String(format: "%+d semitonos", value)
    }
    private var balanceText: String {
        let value = self.player.listeningSettings.balance
        return abs(value) < 0.01 ? "Centro" : String(format: "%.0f %% %@", abs(value) * 100, value < 0 ? "izquierda" : "derecha")
    }
    private var timerText: String {
        switch self.player.sleepTimer {
        case .none: "Desactivado"
        case .endOfTrack: "Al terminar la canción"
        case .deadline(let date): "Hasta las " + date.formatted(date: .omitted, time: .shortened)
        }
    }

    private func audioRows() -> [CarPlayRow] {
        [
            CarPlayRow(title: "Velocidad", subtitle: rateText, symbol: "speedometer", disclosure: true) { [weak self] in self?.showRates() },
            CarPlayRow(title: "Tonalidad", subtitle: pitchText, symbol: "pianokeys", disclosure: true) { [weak self] in self?.showPitch() },
            CarPlayRow(title: "Restablecer velocidad y tono", symbol: "arrow.counterclockwise", enabled: !self.player.equalizer.playback.isOriginal) { [weak self] in
                self?.player.setPlaybackAdjustment(rate: 1, semitones: 0)
            },
            CarPlayRow(title: "Ecualizador", subtitle: self.player.equalizer.settings.enabled ? (self.player.equalizer.preset?.title ?? "Personalizado") : "Desactivado",
                       symbol: "slider.horizontal.3", disclosure: true) { [weak self] in self?.showEqualizer() },
            CarPlayRow(title: "Entre canciones", subtitle: self.player.transitionSettings.mode.title, symbol: "waveform.path", disclosure: true) { [weak self] in self?.showTransitions() },
            CarPlayRow(title: "Igualar volumen", subtitle: self.player.listeningSettings.normalization.title, symbol: "speaker.wave.2", disclosure: true) { [weak self] in self?.showNormalization() },
            CarPlayRow(title: "Balance", subtitle: balanceText, symbol: "hifispeaker.2", disclosure: true) { [weak self] in self?.showBalance() },
            CarPlayRow(title: "Temporizador", subtitle: timerText, symbol: "moon.zzz", disclosure: true) { [weak self] in self?.showTimer() },
            CarPlayRow(title: "BPM y marcadores", subtitle: bpmText, symbol: "waveform", enabled: self.player.current != nil, disclosure: true) { [weak self] in self?.showMarkers() }
        ]
    }

    private func showRates() {
        present(list("Velocidad") { [weak self] in
            guard let self else { return [] }
            return SystemPlaybackControls.playbackRates.map { rate in
                CarPlayRow(title: rate.formatted(.number.precision(.fractionLength(0...2))) + "×",
                           subtitle: rate == 1 ? "Velocidad original" : "Mantiene el tono", symbol: "speedometer",
                           selected: abs(self.player.equalizer.playback.rate - rate) < 0.001) { [weak self] in self?.player.setPlaybackAdjustment(rate: rate) }
            }
        })
    }

    private func showPitch() {
        present(list("Tonalidad") { [weak self] in
            guard let self else { return [] }
            return [
                CarPlayRow(title: pitchText, subtitle: "Mantiene la velocidad", symbol: "pianokeys", enabled: false) {},
                CarPlayRow(title: "Bajar un semitono", symbol: "minus", enabled: self.player.equalizer.playback.semitones > -12) { [weak self] in
                    guard let self else { return }; self.player.setPlaybackAdjustment(semitones: self.player.equalizer.playback.semitones - 1)
                },
                CarPlayRow(title: "Subir un semitono", symbol: "plus", enabled: self.player.equalizer.playback.semitones < 12) { [weak self] in
                    guard let self else { return }; self.player.setPlaybackAdjustment(semitones: self.player.equalizer.playback.semitones + 1)
                },
                CarPlayRow(title: "Tono original", symbol: "arrow.counterclockwise", selected: self.player.equalizer.playback.semitones == 0) { [weak self] in
                    self?.player.setPlaybackAdjustment(semitones: 0)
                }
            ]
        })
    }

    private func showEqualizer() {
        present(list("Ecualizador") { [weak self] in
            guard let self else { return [] }
            let equalizer = self.player.equalizer
            return [CarPlayRow(title: equalizer.settings.enabled ? "Desactivar ecualizador" : "Activar ecualizador",
                               subtitle: equalizer.preset?.title ?? "Curva personalizada", symbol: "power", selected: equalizer.settings.enabled) { [weak self] in
                guard let equalizer = self?.player.equalizer else { return }; equalizer.setEnabled(!equalizer.settings.enabled)
            }] + EqualizerPreset.allCases.map { preset in
                CarPlayRow(title: preset.title, symbol: "slider.horizontal.3", selected: equalizer.settings.enabled && equalizer.preset == preset) { [weak self] in
                    self?.player.equalizer.select(preset); self?.player.equalizer.setEnabled(true)
                }
            }
        })
    }

    private func showTransitions() {
        present(list("Entre canciones") { [weak self] in
            guard let self else { return [] }
            return TransitionMode.allCases.map { mode in
                CarPlayRow(title: mode.title, symbol: "waveform.path", selected: self.player.transitionSettings.mode == mode) { [weak self] in self?.player.setTransition(mode: mode) }
            } + (1...12).map { seconds in
                CarPlayRow(title: "\(seconds) s", subtitle: "Duración del fundido", symbol: "timer",
                           selected: self.player.transitionSettings.duration == Double(seconds), enabled: self.player.transitionSettings.mode != .continuous) { [weak self] in
                    self?.player.setTransition(duration: Double(seconds))
                }
            }
        })
    }

    private func showNormalization() {
        present(list("Igualar volumen") { [weak self] in
            guard let self else { return [] }
            return NormalizationMode.allCases.map { mode in
                CarPlayRow(title: mode.title, subtitle: mode == .off ? "Volumen original" : "Usa ReplayGain o el análisis guardado",
                           symbol: "speaker.wave.2", selected: self.player.listeningSettings.normalization == mode) { [weak self] in self?.player.setListening(normalization: mode) }
            }
        })
    }

    private func showBalance() {
        present(list("Balance") { [weak self] in
            guard let self else { return [] }
            return [
                CarPlayRow(title: balanceText, symbol: "hifispeaker.2", enabled: false) {},
                CarPlayRow(title: "Más a la izquierda", symbol: "arrow.left", enabled: self.player.listeningSettings.balance > -1) { [weak self] in
                    guard let self else { return }; self.player.setListening(balance: self.player.listeningSettings.balance - 0.1)
                },
                CarPlayRow(title: "Más a la derecha", symbol: "arrow.right", enabled: self.player.listeningSettings.balance < 1) { [weak self] in
                    guard let self else { return }; self.player.setListening(balance: self.player.listeningSettings.balance + 0.1)
                },
                CarPlayRow(title: "Centrar balance", symbol: "arrow.counterclockwise", selected: abs(self.player.listeningSettings.balance) < 0.01) { [weak self] in self?.player.setListening(balance: 0) }
            ]
        })
    }

    private func showTimer() {
        present(list("Temporizador") { [weak self] in
            guard let self else { return [] }
            let endSelected: Bool
            if case .endOfTrack = self.player.sleepTimer { endSelected = true } else { endSelected = false }
            return [
                CarPlayRow(title: timerText, symbol: "moon.zzz", enabled: false) {},
                CarPlayRow(title: "Desactivar temporizador", symbol: "xmark", selected: self.player.sleepTimer == nil) { [weak self] in self?.player.setSleepTimer(nil) },
                CarPlayRow(title: "Al terminar la canción", symbol: "music.note", selected: endSelected, enabled: self.player.current != nil) { [weak self] in
                    guard let self, let track = self.player.current else { return }; self.player.setSleepTimer(.endOfTrack(track.id))
                }
            ] + [15, 30, 45, 60].map { minutes in
                CarPlayRow(title: "\(minutes) minutos", symbol: "timer") { [weak self] in
                    self?.player.setSleepTimer(.deadline(Date().addingTimeInterval(Double(minutes * 60))))
                }
            }
        })
    }

    private var bpmText: String {
        if let bpm = self.player.currentSongTools?.bpm { return String(format: "%.0f BPM", bpm.rounded()) }
        return self.player.songAnalysisProgress != nil ? "Analizando…" : "BPM no detectado"
    }

    private func showMarkers() {
        let template = list("BPM y marcadores") { [weak self] in
            guard let self, let track = self.player.current else { return [] }
            let summary = CarPlayRow(title: bpmText, subtitle: self.player.currentDetails?.title ?? track.displayName, symbol: "waveform", enabled: false) {}
            let markers = self.player.currentSongTools?.annotations.markers ?? []
            if markers.isEmpty {
                return [summary, CarPlayRow(title: "Sin marcadores", subtitle: "Esta canción no tiene marcadores guardados.", symbol: "bookmark", enabled: false) {}]
            }
            return [summary] + markers.map { marker in
                CarPlayRow(title: marker.title, subtitle: playbackTime(marker.time), symbol: "bookmark") { [weak self] in
                    guard let self, self.player.current?.id == track.id else { return }
                    self.player.seek(to: marker.time); present(CPNowPlayingTemplate.shared)
                }
            }
        }
        template.emptyViewTitleVariants = ["No hay ninguna canción seleccionada"]
        present(template)
    }
}
