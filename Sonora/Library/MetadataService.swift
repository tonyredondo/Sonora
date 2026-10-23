import Foundation
import ImageIO
import SFBAudioEngine
import SonoraCore

struct FileFingerprint: Codable, Equatable, Sendable {
    let size: UInt64
    let modified: Date?
    let inode: UInt64
    init(_ url: URL) throws {
        let values = try FileManager.default.attributesOfItem(atPath: url.path)
        size = (values[.size] as? NSNumber)?.uint64Value ?? 0
        modified = values[.modificationDate] as? Date
        inode = (values[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
    }
}

struct MetadataSnapshot: Sendable {
    let values: [MetadataField: String]
    let artwork: Data?
    let fingerprint: FileFingerprint
    let canWrite: Bool
    let fileDescription: String
    let duration: Double
    var replayGain = ReplayGain()
    var portableInterpretations = PortableInterpretations()
}

struct MetadataWriteFailure: Identifiable, Sendable {
    let id: String
    let filename: String
    let message: String
}
struct MetadataBatchResult: Sendable {
    let written: Int
    let failures: [MetadataWriteFailure]
}

enum MetadataIOError: LocalizedError {
    case unsupported, changed, readOnly, verification(MetadataField), invalidImage, invalidReplayGain, externalLyrics
    var errorDescription: String? {
        switch self {
        case .unsupported: "Este formato no permite guardar etiquetas en Sonora."
        case .changed: "El archivo ha cambiado desde que lo abriste. Cierra el editor y vuelve a cargarlo."
        case .readOnly: "No hay permiso de escritura para este archivo o su carpeta."
        case .externalLyrics: "Una letra externa seguiría teniendo prioridad. Conserva los tiempos de la letra o actualiza el archivo .lrc o .txt antes de guardar esta sustitución."
        case .verification(let field): "El formato no ha conservado el campo \(field.title). El original no se ha sustituido."
        case .invalidImage: "No se pudo leer la carátula. Elige una imagen JPEG o PNG."
        case .invalidReplayGain: "No se pudieron verificar las etiquetas ReplayGain. El original no se ha sustituido."
        }
    }
}

enum MetadataService {
    static let writableExtensions: Set<String> = ["mp3", "flac", "m4a", "mp4", "wav", "wave", "aif", "aiff", "ogg", "oga", "opus", "wv", "ape"]

    static func read(url: URL, folder: ScopedFolder) async throws -> MetadataSnapshot {
        let job = MetadataJob(folder: folder)
        let worker = Task.detached(priority: .userInitiated) { try job.read(url) }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { job.coordinator.cancel(); worker.cancel() }
    }

    static func save(url: URL, folder: ScopedFolder, expected: FileFingerprint, patch: MetadataPatch, replayGain: ReplayGain? = nil) async throws -> MetadataSnapshot {
        try patch.validate()
        if let replayGain {
            guard let gain = replayGain.trackGain, let peak = replayGain.trackPeak, gain.isFinite, peak.isFinite, peak >= 0,
                  replayGain.albumGain?.isFinite != false, replayGain.albumPeak?.isFinite != false,
                  (replayGain.albumPeak ?? 0) >= 0, (replayGain.albumGain == nil) == (replayGain.albumPeak == nil) else { throw MetadataIOError.invalidReplayGain }
        }
        let job = MetadataJob(folder: folder)
        let worker = Task.detached(priority: .userInitiated) { try job.save(url, expected: expected, patch: patch, replayGain: replayGain) }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { job.coordinator.cancel(); worker.cancel() }
    }

    static func values(_ metadata: AudioMetadata) -> [MetadataField: String] {
        [.title: metadata.title ?? "", .artist: metadata.artist ?? "", .album: metadata.albumTitle ?? "",
         .albumArtist: metadata.albumArtist ?? "", .composer: metadata.composer ?? "", .genre: metadata.genre ?? "",
         .date: metadata.releaseDate ?? "", .comment: metadata.comment ?? "", .lyrics: metadata.lyrics ?? "",
         .trackNumber: metadata.trackNumber.map(String.init) ?? "", .trackTotal: metadata.trackTotal.map(String.init) ?? "",
         .discNumber: metadata.discNumber.map(String.init) ?? "", .discTotal: metadata.discTotal.map(String.init) ?? ""]
    }

    static func replayGain(_ metadata: AudioMetadata?) -> ReplayGain {
        ReplayGain(trackGain: metadata?.replayGainTrackGain, trackPeak: metadata?.replayGainTrackPeak,
                   albumGain: metadata?.replayGainAlbumGain, albumPeak: metadata?.replayGainAlbumPeak)
    }

    static func snapshot(_ url: URL) throws -> MetadataSnapshot {
        if ["caf", "aac"].contains(url.pathExtension.lowercased()) {
            let decoder = try AudioDecoders.open(url); defer { try? decoder.close() }
            let rate = decoder.processingFormat.sampleRate
            return MetadataSnapshot(values: [:], artwork: nil, fingerprint: try FileFingerprint(url), canWrite: false,
                                    fileDescription: "\(url.pathExtension.uppercased()) · \(Int(rate)) Hz · Solo lectura",
                                    duration: Double(max(0, decoder.length)) / rate)
        }
        let file = try AudioFile(readingPropertiesAndMetadataFrom: url)
        let art = file.metadata.attachedPictures(ofType: .frontCover).first?.imageData ?? file.metadata.attachedPictures.first?.imageData
        return MetadataSnapshot(values: values(file.metadata), artwork: art, fingerprint: try FileFingerprint(url),
                                canWrite: writableExtensions.contains(url.pathExtension.lowercased()) && FileManager.default.isWritableFile(atPath: url.path),
                                fileDescription: "\(url.pathExtension.uppercased()) · \(Int(file.properties.sampleRate ?? 0)) Hz", duration: file.properties.duration ?? 0,
                                replayGain: replayGain(file.metadata),
                                portableInterpretations: url.pathExtension.lowercased() == "mp3"
                                    ? PortableInterpretations.read((try? ID3ExportTags.read(from: url)) ?? [:]) : .init())
    }
}

private final class MetadataJob: @unchecked Sendable {
    let coordinator = NSFileCoordinator()
    let folder: ScopedFolder
    init(folder: ScopedFolder) { self.folder = folder }

    func validate(_ url: URL) throws {
        let base = folder.url.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        guard url.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(base),
              try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { throw MetadataIOError.readOnly }
        try Task.checkCancellation()
    }

    func read(_ url: URL) throws -> MetadataSnapshot {
        try validate(url)
        var coordinationError: NSError?
        var result: Result<MetadataSnapshot, Error>?
        coordinator.coordinate(readingItemAt: url, options: .withoutChanges, error: &coordinationError) { local in
            result = Result { try MetadataService.snapshot(local) }
        }
        if let coordinationError { throw coordinationError }
        return try result?.get() ?? { throw CancellationError() }()
    }

    /// TagLib changes a staged copy. Only a verified result replaces the original.
    /// Coordinated provider writes and the fingerprint prevent overwriting external edits.
    func save(_ url: URL, expected: FileFingerprint, patch: MetadataPatch, replayGain: ReplayGain?) throws -> MetadataSnapshot {
        try validate(url)
        guard MetadataService.writableExtensions.contains(url.pathExtension.lowercased()) else { throw MetadataIOError.unsupported }
        var coordinationError: NSError?
        var result: Result<MetadataSnapshot, Error>?
        coordinator.coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { local in
            result = Result {
                guard try FileFingerprint(local) == expected else { throw MetadataIOError.changed }
                guard FileManager.default.isWritableFile(atPath: local.path) else { throw MetadataIOError.readOnly }
                let staged = local.deletingLastPathComponent().appendingPathComponent(".sonora-\(UUID().uuidString).\(local.pathExtension)")
                defer { try? FileManager.default.removeItem(at: staged) }
                try FileManager.default.copyItem(at: local, to: staged)
                let file = try AudioFile(readingPropertiesAndMetadataFrom: staged)
                for (field, value) in patch.values {
                    let text = value.isEmpty ? nil : value
                    switch field {
                    case .title: file.metadata.title = text
                    case .artist: file.metadata.artist = text
                    case .album: file.metadata.albumTitle = text
                    case .albumArtist: file.metadata.albumArtist = text
                    case .composer: file.metadata.composer = text
                    case .genre: file.metadata.genre = text
                    case .date: file.metadata.releaseDate = text
                    case .comment: file.metadata.comment = text
                    case .lyrics: file.metadata.lyrics = text
                    case .trackNumber: file.metadata.trackNumber = Int(value)
                    case .trackTotal: file.metadata.trackTotal = Int(value)
                    case .discNumber: file.metadata.discNumber = Int(value)
                    case .discTotal: file.metadata.discTotal = Int(value)
                    }
                }
                switch patch.artwork {
                case .keep: break
                case .remove: file.metadata.removeAllAttachedPictures()
                case .replace(let data):
                    guard let image = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(image) > 0 else { throw MetadataIOError.invalidImage }
                    file.metadata.removeAttachedPicturesOfType(.frontCover)
                    file.metadata.attachPicture(AttachedPicture(imageData: data, type: .frontCover))
                }
                if let replayGain {
                    file.metadata.replayGainReferenceLoudness = 89
                    file.metadata.replayGainTrackGain = replayGain.trackGain
                    file.metadata.replayGainTrackPeak = replayGain.trackPeak
                    if let gain = replayGain.albumGain, let peak = replayGain.albumPeak {
                        file.metadata.replayGainAlbumGain = gain; file.metadata.replayGainAlbumPeak = peak
                    }
                }
                let date = file.metadata.releaseDate ?? ""
                try file.writeMetadata()
                if ["mp3", "wav", "wave", "aif", "aiff"].contains(staged.pathExtension.lowercased()) {
                    try ID3DateWriter.write(date, to: staged)
                }
                let verified = try MetadataService.snapshot(staged)
                if let replayGain {
                    let pairs: [(Double?, Double?, Double)] = [
                        (replayGain.trackGain, verified.replayGain.trackGain, 0.006),
                        (replayGain.trackPeak, verified.replayGain.trackPeak, 0.000001),
                        (replayGain.albumGain, verified.replayGain.albumGain, 0.006),
                        (replayGain.albumPeak, verified.replayGain.albumPeak, 0.000001)]
                    for (expected, actual, tolerance) in pairs {
                        if let expected { guard let actual, actual.isFinite, abs(actual - expected) <= tolerance else { throw MetadataIOError.invalidReplayGain } }
                    }
                }
                for (field, value) in patch.values {
                    let expectedValue = field.isNumber ? Int(value).map(String.init) ?? "" : value
                    guard verified.values[field] == expectedValue else { throw MetadataIOError.verification(field) }
                }
                switch patch.artwork {
                case .keep: break
                case .remove: guard verified.artwork == nil else { throw MetadataIOError.invalidImage }
                case .replace(let data): guard verified.artwork == data else { throw MetadataIOError.invalidImage }
                }
                try Task.checkCancellation()
                guard try FileFingerprint(local) == expected else { throw MetadataIOError.changed }
                _ = try FileManager.default.replaceItemAt(local, withItemAt: staged)
                return try MetadataService.snapshot(local)
            }
        }
        if let coordinationError { throw coordinationError }
        return try result?.get() ?? { throw CancellationError() }()
    }
}
