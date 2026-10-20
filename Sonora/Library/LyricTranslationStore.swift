import Foundation
import NaturalLanguage
import Observation
import SonoraCore

enum LyricTranslationIssue: LocalizedError {
    case sameLanguage
    var errorDescription: String? { "La letra ya está en el idioma elegido." }
}

/// Owns translation requests beyond the lifetime of a sheet or song selection.
/// Local audio preparation only enqueues here, so an unavailable server cannot block it.
@MainActor @Observable
final class LyricTranslationStore {
    typealias Translator = @MainActor (LyricsDocument, String, String, Bool) async throws -> LyricTranslation
    enum Status: Equatable {
        case queued, translating, ready, sameLanguage, failed(String)
        var busy: Bool { self == .queued || self == .translating }
        var message: String {
            switch self {
            case .queued: "Traducción en cola…"
            case .translating: "Traduciendo la letra completa con Codex…"
            case .ready: "Traducción guardada"
            case .sameLanguage: LyricTranslationIssue.sameLanguage.localizedDescription
            case .failed(let issue): issue
            }
        }
    }
    func message(for key: String) -> String? {
        if statuses[key] == .queued {
            return automaticIssue ?? (waitingForConnection ? "Pendiente de conexión con el servidor." : "Traducción en cola…")
        }
        return statuses[key]?.message
    }
    private(set) var results: [String: LyricTranslation] = [:]
    private(set) var statuses: [String: Status] = [:]
    private(set) var automaticIssue: String?
    var waitingForConnection: Bool { settings.effectiveOffline || settings.endpoint.isEmpty }
    var pendingCount: Int { statuses.filter { $0.value.busy || jobs[$0.key] != nil }.count }
    @ObservationIgnored private let settings: MetadataAssistantSettings
    @ObservationIgnored private let cache: MusicToolsCache
    @ObservationIgnored private let translate: Translator
    @ObservationIgnored private var order: [String] = []
    @ObservationIgnored private var jobs: [String: Job] = [:]
    @ObservationIgnored private var active: Set<String> = []
    @ObservationIgnored private var workers = 0
    @ObservationIgnored private var issueRevision = 0
    @ObservationIgnored private let requests: CodexRequestPool
    @ObservationIgnored private var ownerPriorities: [String: Int] = [:]
    @ObservationIgnored private var automaticSource: String?
    @ObservationIgnored private var automaticTarget: String?
    private struct Job {
        let document: LyricsDocument
        let source: String
        let target: String
        var endpoint: String
        var refresh = false
        var finishingPreparation = false
        var owners: Set<String> = []
        var waiters: [CheckedContinuation<LyricTranslation, Error>] = []
        var refreshWaiters: [CheckedContinuation<LyricTranslation, Error>] = []
    }

    init(cache: MusicToolsCache = .shared, settings: MetadataAssistantSettings = .shared, requests: CodexRequestPool = .shared, translate: Translator? = nil) {
        self.cache = cache; self.settings = settings; self.requests = requests
        self.translate = translate ?? { document, source, target, refresh in
            if Self.sameLanguage(document, source: source, target: target) { throw LyricTranslationIssue.sameLanguage }
            return try await LyricUnderstanding.translate(document, source: source, target: target, refresh: refresh, settings: settings)
        }
        observeConnection()
    }
    private static func sameLanguage(_ document: LyricsDocument, source: String, target: String) -> Bool {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(document.lines.map(\.text).joined(separator: " "))
        guard let from = source == "auto" ? recognizer.dominantLanguage?.rawValue : source else { return false }
        return Locale.Language(identifier: from).languageCode == Locale.Language(identifier: target).languageCode
    }
    func restore(_ document: LyricsDocument, source: String, target: String) async {
        let key = LyricUnderstanding.translationKey(document, source: source, target: target)
        guard results[key] == nil, let value = try? await cache.read(LyricTranslation.self, key: key),
              value.phrases == nil, let valid = try? value.validated(for: document), results[key] == nil else { return }
        results[key] = valid
        if jobs[key] == nil { statuses[key] = .ready }
    }
    func setAutomaticQueue(_ owners: [String], source: String? = nil, target: String? = nil) {
        ownerPriorities = Dictionary(owners.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: min)
        automaticSource = source; automaticTarget = target
        let allowed = Set(ownerPriorities.keys)
        for key in order {
            jobs[key]?.owners.formIntersection(allowed)
            if owners.isEmpty { jobs[key]?.finishingPreparation = false }
            if let job = jobs[key], (source != nil && job.source != source) || (target != nil && job.target != target) {
                jobs[key]?.owners = []
                jobs[key]?.finishingPreparation = false
            }
            if !active.contains(key), let job = jobs[key], job.owners.isEmpty && job.waiters.isEmpty && !job.finishingPreparation {
                jobs[key] = nil; statuses[key] = results[key] == nil ? nil : .ready
            }
        }
        order.removeAll { jobs[$0] == nil }
        start()
    }
    func enqueue(_ document: LyricsDocument, source: String, target: String, owner: String, finishingPreparation: Bool = false) async {
        await restore(document, source: source, target: target)
        let key = LyricUnderstanding.translationKey(document, source: source, target: target)
        guard ownerPriorities[owner] != nil || finishingPreparation, automaticSource == nil || automaticSource == source,
              automaticTarget == nil || automaticTarget == target,
              results[key] == nil,
              document.lines.contains(where: { !$0.text.isEmpty }) else { return }
        if Self.sameLanguage(document, source: source, target: target) {
            statuses[key] = .sameLanguage
            return
        }
        if statuses[key] == .sameLanguage { return }
        if case .failed = statuses[key] { return } // Explicit retry or connection recovery, never a skip-triggered retry storm.
        if jobs[key] == nil {
            jobs[key] = Job(document: document, source: source, target: target, endpoint: settings.endpoint)
            order.append(key); statuses[key] = .queued
        }
        jobs[key]?.owners.insert(owner)
        // A song already undergoing local preparation finishes into the cache,
        // even if the user changes folders before its audio analysis completes.
        if finishingPreparation { jobs[key]?.finishingPreparation = true }
        start()
    }
    func load(_ document: LyricsDocument, source: String, target: String, refresh: Bool = false) async throws -> LyricTranslation {
        if !refresh { await restore(document, source: source, target: target) }
        try Task.checkCancellation()
        let key = LyricUnderstanding.translationKey(document, source: source, target: target)
        if !refresh, let value = results[key] { return value }
        let value: LyricTranslation = try await withCheckedThrowingContinuation { continuation in
            if jobs[key] == nil {
                jobs[key] = Job(document: document, source: source, target: target, endpoint: settings.endpoint, refresh: refresh)
                order.append(key); statuses[key] = .queued
            }
            if refresh && active.contains(key) && jobs[key]?.refresh == false {
                // The active cache-using call cannot be promoted after it starts.
                // Coalesce all explicit refreshes into one following request.
                jobs[key]?.refreshWaiters.append(continuation)
            } else {
                if refresh { jobs[key]?.refresh = true }
                jobs[key]?.waiters.append(continuation)
            }
            start()
        }
        try Task.checkCancellation()
        return value
    }
    func retryAutomatic() {
        issueRevision += 1
        automaticIssue = nil
        for (key, status) in statuses {
            if case .failed = status { statuses[key] = jobs[key] == nil ? nil : .queued }
        }
        start()
    }
    private func observeConnection() {
        withObservationTracking {
            _ = settings.effectiveOffline
            _ = settings.configurationRevision
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                for key in order where !active.contains(key) { jobs[key]?.endpoint = settings.endpoint }
                retryAutomatic()
                observeConnection()
            }
        }
    }
    private func next() -> String? {
        // Explicit requests take priority, then the current playback order.
        let candidates = order.filter { jobs[$0] != nil && !active.contains($0) }
        if let manual = candidates.first(where: { jobs[$0]?.waiters.isEmpty == false }) { return manual }
        guard automaticIssue == nil, !waitingForConnection else { return nil }
        return candidates.compactMap { key -> (key: String, priority: Int)? in
            guard let job = jobs[key],
                  let rank = job.owners.compactMap({ ownerPriorities[$0] }).min()
                    ?? (job.finishingPreparation ? Int.max : nil) else { return nil }
            return (key, rank)
        }.min { $0.priority < $1.priority }?.key
    }
    private func start() {
        while workers < CodexRequestPool.capacity, next() != nil {
            workers += 1
            Task(priority: .utility) { [self] in
                defer { workers -= 1 }
                while next() != nil {
                    await requests.perform {
                        guard let key = next(), let job = jobs[key] else { return }
                        await run(key, job: job)
                    }
                }
            }
        }
    }
    private func run(_ key: String, job: Job) async {
        active.insert(key)
        statuses[key] = .translating
        let connectionRevision = settings.configurationRevision
        let startedIssueRevision = issueRevision
        var retryWhenConnected = false
        let result: Result<LyricTranslation, Error>
        do {
            guard job.endpoint == settings.endpoint else { throw MetadataLookupError.invalidConnection }
            let value = try await translate(job.document, job.source, job.target, job.refresh)
            guard value.phrases == nil else { throw MetadataLookupError.invalidResponse }
            let valid = try value.validated(for: job.document)
            try await cache.write(valid, key: key)
            results[key] = valid; statuses[key] = .ready
            // Another in-flight request may have reported a newer outage.
            if issueRevision == startedIssueRevision { automaticIssue = nil }
            result = .success(value)
        } catch {
            statuses[key] = error is LyricTranslationIssue ? .sameLanguage : .failed(error.localizedDescription)
            // A disconnected server or exhausted plan affects the whole
            // translation queue, but must not block local audio preparation.
            if !(error is LyricTranslationIssue), job.endpoint == settings.endpoint,
               connectionRevision == settings.configurationRevision,
               Self.blocksAutomaticQueue(error) || waitingForConnection {
                issueRevision += 1
                automaticIssue = error.localizedDescription
                retryWhenConnected = true
            }
            result = .failure(error)
        }
        let waiters = jobs[key]?.waiters ?? []
        if let refreshWaiters = jobs[key]?.refreshWaiters, !refreshWaiters.isEmpty {
            jobs[key] = Job(document: job.document, source: job.source, target: job.target, endpoint: job.endpoint,
                            refresh: true, waiters: refreshWaiters)
            statuses[key] = .queued
        } else if retryWhenConnected, !job.refresh,
                  jobs[key]?.owners.isEmpty == false || jobs[key]?.finishingPreparation == true {
            // Retain a failed automatic request for reconnect/retry,
            // without leaving explicit callers waiting indefinitely.
            jobs[key]?.waiters = []
        } else {
            jobs[key] = nil
            order.removeAll { $0 == key }
        }
        active.remove(key)
        for waiter in waiters { waiter.resume(with: result) }
    }
    private static func blocksAutomaticQueue(_ error: Error) -> Bool {
        if error is URLError { return true }
        if case LyricsTranslationError.service(let code, _) = error { return code != "codex_invalid_response" }
        if case MetadataLookupError.unauthorized = error { return true }
        if case MetadataLookupError.invalidConnection = error { return true }
        return false
    }
}
