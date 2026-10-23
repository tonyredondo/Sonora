import Foundation
import ImageIO

enum LocalArtwork {
    static func data(for audio: URL) -> Data? {
        songData(for: audio) ?? data(in: audio.deletingLastPathComponent())
    }
    static func songData(for audio: URL) -> Data? {
        let stem = audio.deletingPathExtension()
        for ext in ["jpg", "png"] {
            if let data = data(at: stem.appendingPathExtension("cover").appendingPathExtension(ext)) { return data }
        }
        return nil
    }
    static func data(in folder: URL) -> Data? {
        for name in ["cover.jpg", "folder.jpg", "cover.png", "folder.png"] {
            if let data = data(at: folder.appendingPathComponent(name)) { return data }
        }
        return nil
    }
    private static func data(at url: URL) -> Data? {
        guard let resource = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]),
              resource.isRegularFile == true, resource.isSymbolicLink != true,
              (resource.fileSize ?? Int.max) <= 10_000_000 else { return nil }
        if resource.isUbiquitousItem == true && resource.ubiquitousItemDownloadingStatus != .current && resource.ubiquitousItemDownloadingStatus != .downloaded { return nil }
        guard let data = try? Data(contentsOf: url),
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 1] as CFDictionary) != nil else { return nil }
        return data
    }
}
