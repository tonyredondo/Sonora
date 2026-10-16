import Foundation
import SonoraCore

enum LyricsSource {
    static func read(for audio: URL, embedded: String, coordinator: NSFileCoordinator) -> (text: String, source: String?) {
        if LyricsDocument(text: embedded).isTimed { return (embedded, "Letra incrustada") }
        let base = audio.deletingPathExtension()
        if let lrc = sidecar(base.appendingPathExtension("lrc"), coordinator: coordinator), LyricsDocument(text: lrc).isTimed {
            return (lrc, "Archivo .lrc")
        }
        if !embedded.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return (embedded, "Letra incrustada") }
        if let text = sidecar(base.appendingPathExtension("txt"), coordinator: coordinator) { return (text, "Archivo .txt") }
        return ("", nil)
    }

    private static func sidecar(_ url: URL, coordinator: NSFileCoordinator) -> String? {
        guard let info = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              info.isRegularFile == true, info.isSymbolicLink != true, (info.fileSize ?? .max) <= 1_000_000 else { return nil }
        var error: NSError?, text: String?
        coordinator.coordinate(readingItemAt: url, options: .withoutChanges, error: &error) { local in
            if let data = try? Data(contentsOf: local) { text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .unicode) }
        }
        return error == nil ? text : nil
    }

    static func importText(_ url: URL) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            guard ["lrc", "txt"].contains(url.pathExtension.lowercased()),
                  let text = sidecar(url, coordinator: NSFileCoordinator()) else { throw CocoaError(.fileReadInapplicableStringEncoding) }
            return text
        }.value
    }
}
