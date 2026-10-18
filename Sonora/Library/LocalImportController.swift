import Foundation
import Observation
import SonoraCore

@MainActor @Observable final class LocalImportController {
    private(set) var copies: [ImportedMusicRecord] = []
    private(set) var isImporting = false
    private(set) var progress: LocalMusicImportProgress?
    private(set) var completedName: String?
    private(set) var completedCopyID: String?
    var issue: String?
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored let storage: URL
    init(storage: URL = LocalMusicImport.defaultStorage) {
        self.storage = storage
        do { copies = try LocalMusicImport.records(in: storage) }
        catch { issue = "No se pudo leer la lista de copias locales: \(error.localizedDescription)" }
    }
    isolated deinit { work?.cancel() }
    func start(_ url: URL, library: MusicLibrary) {
        guard !isImporting, !library.isDeletingFiles else { return }
        guard !library.needsReset else { issue = "Restablece la biblioteca antes de importar música."; return }
        isImporting = true; issue = nil; progress = nil; completedName = nil; completedCopyID = nil
        let token = UUID(); generation = token
        work = Task { [weak self] in
            guard let self else { return }
            defer { isImporting = false; work = nil }
            do {
                let record = try await LocalMusicImport.copy(url, storage: storage) { [weak self] value in
                    Task { @MainActor in if self?.generation == token { self?.progress = value } }
                }
                try await include(record, library: library)
            } catch is CancellationError { issue = "Importación cancelada. No se ha guardado ninguna copia incompleta." }
            catch { issue = "No se pudo completar la importación: \(error.localizedDescription)" }
        }
    }
    /// A published copy must be registered even when cancellation races with
    /// its final move. The scan below intentionally completes that transaction.
    func include(_ record: ImportedMusicRecord, library: MusicLibrary) async throws {
        let access = try ScopedFolder(musicURL(record))
        let tracks = try await Task.detached(priority: .utility) { try FolderScanner.scan(access.url) }.value
        try library.register(access, tracks: tracks, name: record.name + " · Local")
        copies.removeAll { $0.id == record.id }; copies.insert(record, at: 0)
        completedName = record.name; completedCopyID = record.id
    }
    func cancel() { work?.cancel() }
    func musicURL(_ record: ImportedMusicRecord) -> URL { LocalMusicImport.musicURL(record, storage: storage) }
    func copy(containing url: URL) -> ImportedMusicRecord? {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        return copies.first {
            let root = musicURL($0).standardizedFileURL.resolvingSymlinksInPath().path
            return path == root || path.hasPrefix(root + "/")
        }
    }
    func reload() throws { copies = try LocalMusicImport.records(in: storage) }
    func refresh(_ record: ImportedMusicRecord) async throws {
        let storage = storage
        try await Task.detached(priority: .utility) { try LocalMusicImport.refresh(record, storage: storage) }.value
        try reload()
    }
    func remove(_ record: ImportedMusicRecord) async throws {
        guard !isImporting else { throw MusicTextError.invalid("Espera a que termine la importación.") }
        let storage = storage
        try await Task.detached(priority: .utility) { try LocalMusicImport.remove(record, storage: storage) }.value
        copies.removeAll { $0.id == record.id }
    }
}
