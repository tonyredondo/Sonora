import Foundation
import SonoraCore

/// Self-contained ID3 text fields keyed by language; legacy unsuffixed fields remain readable.
/// No server address, paths or credentials travel with the audio.
struct PortableInterpretations: Sendable {
    struct Song: Codable, Sendable {
        var version = 1
        let language: String
        let title: String
        let artist: String
        let album: String
        let lyricsDigest: String
        let interpretation: LyricsInterpretation
        var isValid: Bool {
            version == 1 && PortableInterpretations.languages.contains(language) && interpretation.isValid
                && LyricsInterpretationContext(title: title, artist: artist, album: album).isValid
                && lyricsDigest.utf8.count == 64 && lyricsDigest.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
                && PortableInterpretations.validText(interpretation.explanation)
        }
        func matches(_ document: LyricsDocument, language: String, context: LyricsInterpretationContext) -> Bool {
            isValid && self.language == language && title == context.title && artist == context.artist && album == context.album
                && lyricsDigest == PortableInterpretations.lyricsDigest(document)
        }
    }
    struct Album: Codable, Sendable {
        var version = 1
        let language: String
        let title: String
        let artist: String
        let trackCount: Int
        let missingLyrics: Int
        let interpretation: LyricsInterpretation
        var isValid: Bool {
            version == 1 && PortableInterpretations.languages.contains(language) && interpretation.isValid
                && !title.isEmpty && LyricsInterpretationContext(title: title, artist: artist).isValid
                && (1...100).contains(trackCount) && (0..<trackCount).contains(missingLyrics)
                && PortableInterpretations.validText(interpretation.explanation)
        }
        func matches(language: String, title: String, artist: String) -> Bool {
            isValid && self.language == language
                && self.title.trimmingCharacters(in: .whitespacesAndNewlines) == title.trimmingCharacters(in: .whitespacesAndNewlines)
                && self.artist.trimmingCharacters(in: .whitespacesAndNewlines) == artist.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
    private static func validText(_ text: String) -> Bool {
        !text.unicodeScalars.contains { $0.properties.generalCategory == .control && ![9, 10, 13].contains($0.value) }
    }
    static let languages: Set<String> = ["es", "en", "fr", "de", "it", "pt"]
    var songs: [String: Song] = [:]
    var albums: [String: Album] = [:]
    var isEmpty: Bool { songs.isEmpty && albums.isEmpty }
    static func lyricsDigest(_ document: LyricsDocument) -> String {
        MusicToolsCache.digest(document.lines.map(\.text).joined(separator: "\n"))
    }
    static func read(_ values: [String: [String]]) -> Self {
        func decode<T: Decodable>(_ type: T.Type, key: String) -> T? {
            guard let fields = values[key], fields.count == 1, let text = fields.first, text.utf8.count <= 131072 else { return nil }
            return try? JSONDecoder().decode(type, from: Data(text.utf8))
        }
        var result = Self()
        // Legacy exports stored only one language in each unsuffixed field.
        if let song = decode(Song.self, key: "SONORA_SONG_ABOUT"), song.isValid { result.songs[song.language] = song }
        if let album = decode(Album.self, key: "SONORA_ALBUM_ABOUT"), album.isValid { result.albums[album.language] = album }
        for language in languages {
            if let song = decode(Song.self, key: "SONORA_SONG_ABOUT:\(language)"), song.isValid, song.language == language {
                result.songs[language] = song
            }
            if let album = decode(Album.self, key: "SONORA_ALBUM_ABOUT:\(language)"), album.isValid, album.language == language {
                result.albums[language] = album
            }
        }
        return result
    }
    func tags() throws -> [String: [String]] {
        var tags: [String: [String]] = [:]
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        for (language, song) in songs {
            guard song.isValid, song.language == language else { throw MetadataLookupError.invalidResponse }
            tags["SONORA_SONG_ABOUT:\(language)"] = [String(decoding: try encoder.encode(song), as: UTF8.self)]
        }
        for (language, album) in albums {
            guard album.isValid, album.language == language else { throw MetadataLookupError.invalidResponse }
            tags["SONORA_ALBUM_ABOUT:\(language)"] = [String(decoding: try encoder.encode(album), as: UTF8.self)]
        }
        return tags
    }
}
