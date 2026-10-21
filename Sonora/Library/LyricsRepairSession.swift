import Foundation
import Observation
import SonoraCore

/// Owns one file snapshot and its review. Playback and draft changes never start
/// another analysis; saving uses the same conflict-checked path as the editor.
@MainActor @Observable final class LyricsRepairSession {
    let track: AudioTrack
    let player: PlaybackController
    let settings: MetadataAssistantSettings
    private(set) var snapshot: MetadataSnapshot?
    private(set) var review: LyricsRepair?
    private(set) var loading = false
    private(set) var saving = false
    private(set) var saved = false
    private(set) var isCached = false
    private(set) var warning: String?
    private(set) var timingIssue: LyricsRepair.TimingIssue?
    private(set) var phase = "Leyendo letra…"
    private(set) var edits: [Int:LyricsRepair.Edit] = [:]
    private(set) var kept: Set<Int> = []
    var onlyCompletions = false {
        didSet { if oldValue != onlyCompletions { preparedText = nil; timingIssue = nil; issue = nil } }
    }
    var issue: String?
    @ObservationIgnored private let transport: any MetadataLookupTransport
    @ObservationIgnored private var operation: Task<Void,Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var originalLyrics = ""
    @ObservationIgnored private var audioDuration: Double?
    @ObservationIgnored private var preparedText: String?
    private(set) var previewEnd: Double?
    enum PreviewReference: Equatable { case fragment, current, proposed }
    private struct PreviewSelection: Equatable {
        let proposalID: Int
        let reference: PreviewReference
        let start: Double
    }
    private var previewSelection: PreviewSelection?
    var title: String { snapshot?.values[.title].flatMap { $0.isEmpty ? nil : $0 } ?? track.displayName }
    var canAnalyze: Bool { snapshot?.canWrite == true && track.cue == nil && !settings.endpoint.isEmpty && !loading && !saving }
    var canListen: Bool { player.isEditingTrackCurrent(track) }
    var visibleProposals: [LyricsRepair.Proposal] {
        review?.proposals.filter { $0.kind != .unrecognized && (!onlyCompletions || $0.kind == .completion) } ?? []
    }
    var selectedCount: Int { visibleProposals.filter { edits[$0.id] != nil }.count }
    var timingProblemProposals: [LyricsRepair.Proposal] {
        timingIssue?.proposalIDs.compactMap { id in review?.proposals.first { $0.id == id } } ?? []
    }

    init(player: PlaybackController, track: AudioTrack, settings: MetadataAssistantSettings = .shared,
         transport: any MetadataLookupTransport = MetadataURLSessionTransport(requestTimeout:180,resourceTimeout:210)) {
        self.player = player; self.track = track; self.settings = settings; self.transport = transport
    }
    func load() async {
        guard snapshot == nil else { return }
        do {
            let value = try await player.readMetadata(for:track)
            let folder = try player.folderAccess(for:track)
            let text = try await LyricsAudioPreparation.existingText(track:track,folder:folder,embedded:value.values[.lyrics] ?? "",expected:value.fingerprint)
            try Task.checkCancellation()
            guard value.canWrite, track.cue == nil else { throw MetadataIOError.unsupported }
            let duration = try await LyricsAudioPreparation.duration(track:track,folder:folder,expected:value.fingerprint)
            try LyricsRepair.validateOriginal(text,duration:duration)
            originalLyrics = text; audioDuration = duration; snapshot = value; phase = "Preparada para analizar"
        } catch is CancellationError { }
        catch {
            issue = error.localizedDescription
            await MetadataDiagnostics.shared.recordFailure(error, stage: .lyricsLoad)
        }
    }
    func analyze() async {
        guard review == nil, canAnalyze, let snapshot, let audioDuration else { return }
        let token = UUID(); generation = token; loading = true; issue = nil
        let task = Task<Void,Never> { [weak self] in
            guard let self else { return }
            await self.performAnalysis(snapshot,duration:audioDuration,token:token)
        }
        operation = task
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        if generation == token { operation = nil; loading = false }
    }
    private func performAnalysis(_ snapshot: MetadataSnapshot, duration: Double, token: UUID) async {
        var stage = MetadataDiagnosticStage.lyricsAnalysis
        do {
            phase = settings.effectiveOffline ? "Buscando análisis guardado…" : "Preparando audio y transcribiendo…"
            let folder = try player.folderAccess(for:track), track = track
            let connection = try MetadataProxyConnection(endpoint:settings.endpoint,token:settings.savedToken())
            let client = LyricsSynchronizationClient(connection:connection,cache:settings.cache,transport:transport)
            let analysis = try await client.transcription(duration:duration,offline:settings.effectiveOffline) {
                try await LyricsAudioPreparation.prepare(track:track,folder:folder,expected:snapshot.fingerprint)
            }
            try Task.checkCancellation()
            guard generation == token else { return }
            phase = "Comparando palabras y fragmentos…"
            stage = .lyricsComparison
            let original = originalLyrics
            let worker = Task.detached(priority:.userInitiated) {
                try Task.checkCancellation()
                let result = try LyricsRepair(original:original,transcript:analysis.value)
                try Task.checkCancellation(); return result
            }
            let result = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
            try Task.checkCancellation()
            guard generation == token else { return }
            review = result; isCached = analysis.isCached; warning = analysis.warning; phase = "Revisión preparada"
        } catch is CancellationError { }
        catch {
            if generation == token {
                issue = error.localizedDescription
                await MetadataDiagnostics.shared.recordFailure(error, stage: stage)
            }
        }
    }
    func cancel() {
        generation = UUID(); operation?.cancel(); operation = nil; loading = false; stopPreview()
    }
    func accept(_ proposal: LyricsRepair.Proposal) {
        guard proposal.kind != .unrecognized else { keep(proposal); return }
        setEdit(proposal,text:proposal.suggested,startTime:proposal.start)
    }
    func setEdit(_ proposal: LyricsRepair.Proposal, text: String, startTime: Double?) {
        if proposal.kind == .timing, let startTime, startTime.isFinite, let original = proposal.originalStart,
           (startTime * 100).rounded() == (original * 100).rounded() { keep(proposal); return }
        edits[proposal.id] = .init(text:text,startTime:startTime); kept.remove(proposal.id); preparedText = nil
        timingIssue = nil; issue = nil
    }
    func keep(_ proposal: LyricsRepair.Proposal) { edits.removeValue(forKey:proposal.id); kept.insert(proposal.id); preparedText = nil; timingIssue = nil; issue = nil }
    func undo(_ proposal: LyricsRepair.Proposal) { edits.removeValue(forKey:proposal.id); kept.remove(proposal.id); preparedText = nil; timingIssue = nil; issue = nil }
    func draft() throws -> String {
        preparedText = nil; timingIssue = nil
        do {
            guard let review, selectedCount > 0 else { throw LyricsRepairError.invalidSelection }
            let text = try review.applying(edits,onlyCompletions:onlyCompletions)
            guard text != originalLyrics else { throw LyricsRepairError.invalidSelection }
            issue = nil; preparedText = text; return text
        } catch {
            timingIssue = error as? LyricsRepair.TimingIssue
            issue = error.localizedDescription
            throw error
        }
    }
    func save(_ text: String) async {
        guard !saving, text == preparedText, let snapshot else { issue = LyricsRepairError.invalidSelection.localizedDescription; return }
        saving = true; issue = nil; stopPreview(); defer { saving = false }
        do {
            let folder = try player.folderAccess(for:track)
            let current = try await LyricsAudioPreparation.existingText(track:track,folder:folder,embedded:snapshot.values[.lyrics] ?? "",expected:snapshot.fingerprint)
            guard current == originalLyrics else { throw MetadataIOError.changed }
            try await player.saveMetadata(for:track,expected:snapshot.fingerprint,patch:MetadataPatch(values:[.lyrics:text]))
            saved = true
        } catch {
            issue = error.localizedDescription
            await MetadataDiagnostics.shared.recordFailure(error, stage: .lyricsSave)
        }
    }
    func canPreview(at time: Double?) -> Bool {
        guard canListen, !saving, let time, time.isFinite, let audioDuration else { return false }
        return time >= 0 && time < audioDuration
    }
    func isPreviewing(_ proposal: LyricsRepair.Proposal, reference: PreviewReference, at time: Double?) -> Bool {
        guard let time, canListen, previewEnd != nil else { return false }
        return previewSelection == PreviewSelection(proposalID:proposal.id,reference:reference,start:time)
    }
    func listen(_ proposal: LyricsRepair.Proposal, reference: PreviewReference = .fragment, at time: Double? = nil) {
        let start = time ?? (reference == .current ? proposal.originalStart : proposal.start)
        guard canPreview(at:start), let start else { return }
        let selection = PreviewSelection(proposalID:proposal.id,reference:reference,start:start)
        if previewSelection == selection { stopPreview(); return }
        stopPreview()
        let from = max(0,start - 0.5)
        player.seek(to:from); player.resume()
        // Both timing references get the same listening window for comparison.
        let end = reference == .fragment ? max(start + 1,proposal.end ?? start + 4) + 0.3 : from + 4
        previewEnd = min(audioDuration ?? end,end)
        previewSelection = selection
    }
    func checkPreview() {
        if !canListen { stopPreview(); return }
        if let end = previewEnd, player.currentTime >= end { stopPreview() }
    }
    func stopPreview() {
        let playingOurFragment = previewEnd != nil && canListen
        previewEnd = nil; previewSelection = nil
        if playingOurFragment { player.pause() }
    }
}
