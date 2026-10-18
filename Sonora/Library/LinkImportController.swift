import Foundation
import Observation
import SonoraCore
import UIKit

/// Owns one durable import. URLSession owns network I/O; only a completely
/// validated local copy is handed to the library. Access links stay in app data.
@MainActor @Observable final class LinkImportController: NSObject {
    static let sessionIdentifier = "com.tonyredondo.Sonora.link-imports"
    private(set) var progressBytes: Int64 = 0
    private(set) var expectedBytes: Int64 = 0
    private(set) var completedName: String?
    private(set) var cancelling = false
    var issue: String?
    private var job: Job?
    @ObservationIgnored private let library: MusicLibrary
    @ObservationIgnored private let copies: LocalImportController
    @ObservationIgnored private let client: WeTransferClient
    @ObservationIgnored private let directory: URL
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var transferTask: URLSessionDownloadTask?
    @ObservationIgnored private var restoring = false
    @ObservationIgnored private var backgroundCompletion: (() -> Void)?
    @ObservationIgnored private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        configuration.isDiscretionary = false
        configuration.sessionSendsLaunchEvents = true
        configuration.waitsForConnectivity = true
        return URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
    }()
    private enum Phase: String, Codable { case resolving, downloading, ready, extracting, adding, failed }
    private struct Job: Codable {
        let id: UUID
        let input: String
        let customName: String
        var phase: Phase = .resolving
        var originID: String?
        var name = "WeTransfer"
        var filename = "WeTransfer.zip"
        var bytes: Int64 = 0
        var taskIdentifier: Int?
        var failure: String?
    }
    private var stateURL: URL {
        directory.appendingPathComponent("pending.json")
    }
    private func payloadDirectory(_ id: UUID) -> URL {
        directory.appendingPathComponent("Downloads", isDirectory: true).appendingPathComponent(id.uuidString, isDirectory: true)
    }
    private func payloadURL(_ id: UUID) -> URL { payloadDirectory(id).appendingPathComponent("payload.download") }
    var hasPendingImport: Bool { job != nil }
    var isImporting: Bool { job != nil && job?.phase != .failed }
    var canRetry: Bool { job?.phase == .failed }
    var canCancel: Bool { job != nil && job?.phase != .adding && !cancelling }
    var fraction: Double? {
        guard job?.phase == .downloading, expectedBytes > 0 else { return nil }
        return min(1, Double(progressBytes) / Double(expectedBytes))
    }
    var status: String {
        if cancelling { return "Cancelando importación…" }
        switch job?.phase {
        case .resolving: return "Comprobando enlace…"
        case .downloading: return "Descargando \(job?.name ?? "WeTransfer")"
        case .ready: return "Descarga completada"
        case .extracting: return "Descomprimiendo y preparando música…"
        case .adding: return "Añadiendo a la biblioteca…"
        case .failed: return "No se pudo completar la importación"
        case nil: return ""
        }
    }

    init(library: MusicLibrary, copies: LocalImportController, client: WeTransferClient = WeTransferClient(), directory: URL? = nil) {
        self.library = library; self.copies = copies; self.client = client
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("SonoraLinkImports", isDirectory: true)
        super.init()
        do {
            if FileManager.default.fileExists(atPath: stateURL.path) {
                let data = try Data(contentsOf: stateURL)
                guard data.count <= 64 * 1024 else { throw CocoaError(.fileReadCorruptFile) }
                let value = try JSONDecoder().decode(Job.self, from: data)
                _ = try WeTransferLink(value.input)
                guard value.bytes >= 0, value.name.utf8.count <= 4096,
                      !value.filename.contains("/"), !value.filename.contains("\\"),
                      AudioTrack(relativePath: value.filename) != nil else { throw CocoaError(.fileReadCorruptFile) }
                job = value; issue = value.failure; expectedBytes = value.bytes
            }
        } catch { issue = "No se pudo recuperar la importación pendiente: \(error.localizedDescription)" }
    }
    isolated deinit { work?.cancel() }

    func start(_ input: String, name: String) {
        guard job == nil else { return }
        guard !library.isDeletingFiles else { issue = "Espera a que termine el borrado de archivos."; return }
        guard !library.needsReset else { issue = "Restablece la biblioteca antes de importar música."; return }
        do {
            _ = try WeTransferLink(input)
            let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard name.utf8.count <= 4096 else { throw MusicTextError.invalid("El nombre es demasiado largo.") }
            job = Job(id: UUID(), input: input.trimmingCharacters(in: .whitespacesAndNewlines), customName: name)
            issue = nil; completedName = nil; progressBytes = 0; expectedBytes = 0; cancelling = false
            try persist(); resolve()
        } catch { if job != nil { fail(error) } else { issue = error.localizedDescription } }
    }
    func retry() {
        guard !library.isDeletingFiles else { return }
        guard let current = job, current.phase == .failed, work == nil else { return }
        issue = nil; cancelling = false; job?.failure = nil
        if FileManager.default.fileExists(atPath: payloadURL(current.id).path) {
            beginImport()
        } else { resolve() }
    }
    func cancel() {
        guard let current = job, canCancel else { return }
        cancelling = true
        if let work { work.cancel() }
        else {
            transferTask?.cancel(); transferTask = nil
            endCancelled(current)
        }
    }
    func restore() async {
        guard let current = job, work == nil, !restoring else { return }
        restoring = true; defer { restoring = false }
        guard !library.needsReset else { fail(MusicTextError.invalid("Restablece la biblioteca antes de importar música.")); return }
        if current.phase == .failed { return }
        if FileManager.default.fileExists(atPath: payloadURL(current.id).path) || current.phase == .adding {
            beginImport(); return
        }
        if current.phase == .downloading {
            let tasks = await withCheckedContinuation { continuation in session.getAllTasks { continuation.resume(returning: $0) } }
            guard job?.id == current.id, job?.phase == .downloading else { return }
            if let existing = tasks.first(where: { $0.taskIdentifier == current.taskIdentifier && $0.taskDescription == current.id.uuidString }) as? URLSessionDownloadTask {
                transferTask = existing
                progressBytes = max(0, existing.countOfBytesReceived)
                expectedBytes = existing.countOfBytesExpectedToReceive > 0 ? existing.countOfBytesExpectedToReceive : current.bytes
                existing.resume(); return
            }
        }
        resolve()
    }
    func handleBackgroundEvents(_ completion: @escaping () -> Void) {
        backgroundCompletion = completion
        _ = session
    }
    private func resolve() {
        guard let current = job, work == nil else { return }
        job?.phase = .resolving
        work = Task { [weak self] in
            guard let self else { return }; defer { work = nil }
            do {
                try Task.checkCancellation(); try persist()
                let parsed = try WeTransferLink(current.input)
                if let id = parsed.transferID, let record = try LocalMusicImport.records().first(where: { $0.linkID == "wetransfer:" + id }) {
                    try await include(record, for: current); return
                }
                let transfer = try await client.inspect(current.input)
                if let record = try LocalMusicImport.records().first(where: { $0.linkID == transfer.importIdentifier }) {
                    try await include(record, for: current); return
                }
                try LocalMusicImport.checkDownloadSpace(transfer.bytes)
                let url = try await client.downloadURL(for: transfer)
                try Task.checkCancellation(); guard job?.id == current.id else { return }
                job?.originID = transfer.importIdentifier
                job?.name = current.customName.isEmpty ? transfer.name : current.customName
                job?.filename = transfer.filename; job?.bytes = transfer.bytes; job?.phase = .downloading
                expectedBytes = transfer.bytes; progressBytes = 0
                let task = session.downloadTask(with: url)
                transferTask = task; task.taskDescription = current.id.uuidString; job?.taskIdentifier = task.taskIdentifier
                try persist(); task.resume()
            } catch {
                // URLSession reports cancellation as URLError.cancelled rather
                // than CancellationError. It must still discard this job.
                if Task.isCancelled { endCancelled(current) }
                else { fail(error) }
            }
        }
    }
    private func beginImport() {
        guard let current = job, work == nil else { return }
        // Network can finish while suspended; extraction resumes on activation.
        guard UIApplication.shared.applicationState == .active else {
            job?.phase = .ready
            do { try persist() } catch { fail(error) }
            return
        }
        job?.phase = .extracting; progressBytes = 0
        work = Task { [weak self] in
            guard let self else { return }; defer { work = nil }
            do {
                try persist()
                guard let origin = current.originID else { throw WeTransferError.invalidResponse }
                let record = try await LocalMusicImport.downloaded(payloadURL(current.id), filename: current.filename,
                    name: current.name, linkID: origin, importID: current.id) { [weak self] progress in
                        Task { @MainActor in if self?.job?.id == current.id { self?.progressBytes = progress.bytes } }
                    }
                // After publication cancellation cannot strand a completed copy.
                try await include(record, for: current)
            } catch is CancellationError { endCancelled(current) }
            catch { fail(error) }
        }
    }
    private func include(_ record: ImportedMusicRecord, for current: Job) async throws {
        guard job?.id == current.id else { return }
        job?.originID = record.linkID; job?.name = record.name; job?.phase = .adding; try persist()
        try await copies.include(record, library: library)
        job = nil; transferTask = nil; cancelling = false; completedName = record.name; issue = nil
        do { try clean(current) }
        catch { issue = "La música está guardada, pero no se pudieron limpiar todos los archivos temporales: \(error.localizedDescription)" }
    }
    private func fail(_ error: Error) {
        transferTask?.cancel(); transferTask = nil; cancelling = false
        issue = error.localizedDescription; job?.phase = .failed; job?.failure = issue
        do { try persist() } catch { issue = "No se pudo guardar el estado de la importación: \(error.localizedDescription)" }
    }
    private func endCancelled(_ current: Job) {
        guard job?.id == current.id else { return }
        job = nil; cancelling = false; transferTask = nil
        do { try clean(current); issue = "Importación cancelada." }
        catch { issue = "No se pudieron limpiar los archivos temporales de la importación: \(error.localizedDescription)" }
    }
    private func clean(_ current: Job) throws {
        for url in [payloadDirectory(current.id), LocalMusicImport.linkStaging(current.id), stateURL] {
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        }
    }
    private func persist() throws {
        guard let job else { return }
        try FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(job).write(to: stateURL, options: .atomic)
    }
}

extension LinkImportController: URLSessionDownloadDelegate {
    // The session explicitly uses OperationQueue.main. Forward synchronously so
    // the temporary download is moved before this delegate callback returns.
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        MainActor.assumeIsolated {
            guard let current = job, current.taskIdentifier == downloadTask.taskIdentifier,
                  downloadTask.taskDescription == current.id.uuidString else { return }
            do {
                guard let response = downloadTask.response as? HTTPURLResponse else { throw WeTransferError.invalidResponse }
                guard (200..<300).contains(response.statusCode) else { throw WeTransferError.response(response.statusCode) }
                guard response.mimeType != "text/html", response.mimeType != "application/json" else { throw WeTransferError.invalidResponse }
                let destination = payloadURL(current.id)
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
                try FileManager.default.moveItem(at: location, to: destination)
                job?.phase = .ready; transferTask = nil; try persist(); beginImport()
            } catch { fail(error) }
        }
    }
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                               totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        MainActor.assumeIsolated {
            guard job?.taskIdentifier == downloadTask.taskIdentifier, downloadTask.taskDescription == job?.id.uuidString else { return }
            progressBytes = totalBytesWritten
            if totalBytesExpectedToWrite > 0 { expectedBytes = totalBytesExpectedToWrite }
        }
    }
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        MainActor.assumeIsolated {
            guard let error, job?.taskIdentifier == task.taskIdentifier, task.taskDescription == job?.id.uuidString else { return }
            if (error as NSError).code == NSURLErrorCancelled, cancelling, let current = job { endCancelled(current) }
            else { fail(error) }
        }
    }
    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        MainActor.assumeIsolated {
            let completion = backgroundCompletion; backgroundCompletion = nil; completion?()
        }
    }
}
