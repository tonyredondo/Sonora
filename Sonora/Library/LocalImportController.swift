import Foundation
import Observation
import SonoraCore

@MainActor @Observable final class LocalImportController {
    private(set) var copies: [ImportedMusicRecord] = []
    private(set) var isImporting = false
    private(set) var progress: LocalMusicImportProgress?
    private(set) var completedName: String?
    var issue: String?
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    init() {
        do { copies = try LocalMusicImport.records() }
        catch { issue = "No se pudo leer la lista de copias locales: \(error.localizedDescription)" }
    }
    isolated deinit { work?.cancel() }
    func start(_ url: URL, library: MusicLibrary) {
        guard !isImporting else { return }
        guard !library.needsReset else { issue = "Restablece la biblioteca antes de importar música."; return }
        isImporting = true; issue = nil; progress = nil; completedName = nil
        let token = UUID(); generation = token
        work = Task { [weak self] in
            guard let self else { return }
            defer { isImporting = false; work = nil }
            do {
                let record = try await LocalMusicImport.copy(url) { [weak self] value in
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
        let access = try ScopedFolder(LocalMusicImport.musicURL(record))
        let tracks = try await Task.detached(priority: .utility) { try FolderScanner.scan(access.url) }.value
        try library.register(access, tracks: tracks, name: record.name + " · Local")
        copies.removeAll { $0.id == record.id }; copies.insert(record, at: 0)
        completedName = record.name
    }
    func cancel() { work?.cancel() }
    func remove(_ record: ImportedMusicRecord) async throws {
        guard !isImporting else { throw MusicTextError.invalid("Espera a que termine la importación.") }
        try await Task.detached(priority: .utility) { try LocalMusicImport.remove(record) }.value
        copies.removeAll { $0.id == record.id }
    }
}
