import Foundation
import Observation
import SonoraCore

struct VolumeAnalysisSelection: Identifiable {
    let id = UUID()
    let tracks: [AudioTrack]
    var album = false
}

/// Owns one presented manual analysis. A cancelled/replaced session cannot publish
/// a late worker result. Original-file writes use the player's metadata transaction.
@MainActor @Observable
final class VolumeAnalysisSession {
    let selection: VolumeAnalysisSelection
    private(set) var targets: [VolumeAnalysisTarget] = []
    private(set) var results: [String: VolumeTrackMeasurement] = [:]
    private(set) var albumResult: VolumeAlbumMeasurement?
    private(set) var failures: [MetadataWriteFailure] = []
    private(set) var saveResult: MetadataBatchResult?
    private(set) var saveTargetCount = 0
    private(set) var isLoading = true
    private(set) var isAnalyzing = false
    private(set) var isSaving = false
    private(set) var cancellationRequested = false
    private(set) var analyzedCount = 0
    private(set) var reusedCount = 0
    private(set) var completedCount = 0
    private(set) var currentFraction = 0.0
    private(set) var currentFilename = ""
    private(set) var status = "Listo para analizar"
    var issue: String?
    @ObservationIgnored private let player: PlaybackController
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var runID = UUID()
    @ObservationIgnored private var accessFailures: [MetadataWriteFailure] = []
    @ObservationIgnored private var loaded = false

    var isWorking: Bool { isAnalyzing || isSaving }
    var progress: Double {
        let total = isSaving ? saveTargetCount : targets.count
        return total == 0 ? 0 : min(1, (Double(completedCount) + currentFraction) / Double(total))
    }
    var saveableTargets: [VolumeAnalysisTarget] {
        targets.filter { $0.cue == nil && results[$0.id] != nil && MetadataService.writableExtensions.contains($0.url.pathExtension.lowercased()) }
    }
    init(player: PlaybackController, selection: VolumeAnalysisSelection) { self.player = player; self.selection = selection }
    isolated deinit { work?.cancel() }

    func load() async {
        guard !loaded else { return }
        isLoading = true; defer { isLoading = false }
        var seen: Set<String> = []
        for track in selection.tracks {
            do {
                if let target = try player.volumeTargets(for: [track]).first, seen.insert(target.id).inserted { targets.append(target) }
            } catch { accessFailures.append(.init(id: track.id, filename: track.filename, message: error.localizedDescription)) }
        }
        failures = accessFailures
        do {
            try await refreshResults()
            loaded = true
            if !results.isEmpty { status = "Resultados guardados" }
        } catch is CancellationError { }
        catch { issue = error.localizedDescription }
    }

    private func refreshResults() async throws {
        let fingerprints = try await VolumeAnalysisService.availableFingerprints(targets)
        results = Dictionary(uniqueKeysWithValues: targets.compactMap { target in
            guard let value = player.volumeAnalysis.records[target.id], value.fingerprint == fingerprints[target.id] else { return nil }
            return (target.id, value)
        })
        albumResult = nil
        if selection.album, results.count == targets.count,
           let id = results.values.first?.albumID, let album = player.volumeAnalysis.albums[id],
           Set(album.members.keys) == Set(targets.map(\.id)),
           album.members.allSatisfy({ fingerprints[$0.key] == $0.value }) { albumResult = album }
    }

    func start(force: Bool = false) {
        guard loaded, !isWorking, !targets.isEmpty, player.volumeAnalysis.issue == nil else { return }
        let token = UUID(); runID = token
        isAnalyzing = true; cancellationRequested = false; issue = nil; saveResult = nil
        analyzedCount = 0; reusedCount = 0; completedCount = 0; currentFraction = 0
        status = "Analizando…"; failures = accessFailures
        work = Task { [weak self] in
            guard let self else { return }
            defer { if runID == token { isAnalyzing = false; work = nil; currentFilename = ""; currentFraction = 0 } }
            var pending: [String: VolumeTrackMeasurement] = [:]
            @MainActor func commit() throws {
                // A closed sheet can finish cancelling after its source has
                // already been forgotten. Never recreate those references.
                for id in Array(pending.keys) where player.library.state.songs[id] == nil {
                    pending.removeValue(forKey: id); results.removeValue(forKey: id)
                    analyzedCount = max(0, analyzedCount - 1)
                    if let target = targets.first(where: { $0.id == id }) { failures.append(unavailable(target)) }
                }
                guard !pending.isEmpty else { return }
                try player.volumeAnalysis.record(.init(records: pending, album: nil)); pending = [:]
            }
            do {
                try Task.checkCancellation(); try await refreshResults()
                if selection.album {
                    guard failures.isEmpty else { throw CocoaError(.fileReadNoPermission) }
                    guard targets.allSatisfy({ player.library.state.songs[$0.id] != nil }) else { throw CocoaError(.fileReadNoSuchFile) }
                    if !force, albumResult != nil { reusedCount = targets.count; completedCount = targets.count }
                    else {
                        let value = try await VolumeAnalysisService.analyze(targets, album: true) { value in
                            Task { @MainActor in self.receive(value, token: token, base: 0) }
                        }
                        try Task.checkCancellation()
                        guard targets.allSatisfy({ player.library.state.songs[$0.id] != nil }) else { throw CocoaError(.fileReadNoSuchFile) }
                        try player.volumeAnalysis.record(value)
                        results = value.records; albumResult = value.album; analyzedCount = value.records.count
                        completedCount = targets.count
                    }
                } else {
                    for (index, target) in targets.enumerated() {
                        try Task.checkCancellation()
                        guard player.library.state.songs[target.id] != nil else {
                            failures.append(unavailable(target)); completedCount = index + 1; continue
                        }
                        if !force, results[target.id] != nil { reusedCount += 1; completedCount = index + 1; continue }
                        do {
                            let value = try await VolumeAnalysisService.analyze([target], album: false) { value in
                                Task { @MainActor in self.receive(value, token: token, base: index) }
                            }
                            try Task.checkCancellation()
                            guard player.library.state.songs[target.id] != nil else {
                                failures.append(unavailable(target)); completedCount = index + 1; continue
                            }
                            for (id, record) in value.records { results[id] = record; pending[id] = record }
                            analyzedCount += value.records.count
                            if pending.count >= 16 { try commit() }
                        } catch is CancellationError { throw CancellationError() }
                        catch { failures.append(.init(id: target.id, filename: target.url.lastPathComponent, message: error.localizedDescription)) }
                        completedCount = index + 1; currentFraction = 0
                    }
                    try commit()
                }
                status = failures.isEmpty ? "Análisis completado" : "Análisis con incidencias"
            } catch is CancellationError {
                do { try commit() } catch { issue = "No se pudieron guardar los resultados terminados: \(error.localizedDescription)" }
                status = "Análisis cancelado"
            } catch { issue = error.localizedDescription; status = "Análisis con incidencias" }
            if analyzedCount > 0 { player.volumeAnalysisDidChange() }
        }
    }

    private func unavailable(_ target: VolumeAnalysisTarget) -> MetadataWriteFailure {
        .init(id: target.id, filename: target.url.lastPathComponent, message: "La canción ya no está en la biblioteca. Vuelve a abrir su carpeta para analizarla.")
    }

    private func receive(_ value: VolumeAnalysisProgress, token: UUID, base: Int) {
        guard runID == token, isAnalyzing, !cancellationRequested else { return }
        let completed = base + value.completed
        guard completed > completedCount || (completed == completedCount && value.fraction >= currentFraction) else { return }
        completedCount = completed; currentFraction = value.fraction; currentFilename = value.filename
    }
    func cancel() {
        guard isWorking else { return }
        cancellationRequested = true; status = isSaving ? "Terminando el guardado actual…" : "Cancelando…"
        work?.cancel()
    }
    func saveTags() {
        guard !isWorking, !saveableTargets.isEmpty, player.volumeAnalysis.issue == nil else { return }
        let selected = saveableTargets
        isSaving = true; cancellationRequested = false; completedCount = 0; saveTargetCount = selected.count
        issue = nil; saveResult = nil
        work = Task { [weak self] in
            guard let self else { return }
            defer { isSaving = false; work = nil }
            saveResult = await player.saveVolumeTags(selected) { self.completedCount = $0 }
            do { try await refreshResults() } catch is CancellationError { } catch { issue = error.localizedDescription }
        }
    }
    func resetSavedAnalysis() {
        guard !isWorking else { return }
        player.volumeAnalysis.reset(); results = [:]; albumResult = nil; saveResult = nil
        analyzedCount = 0; reusedCount = 0; completedCount = 0; issue = nil
        status = "Listo para analizar"; player.volumeAnalysisDidChange()
    }
}
