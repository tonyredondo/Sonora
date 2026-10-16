import Foundation
import ImageIO

enum LocalArtwork {
    static func data(in folder: URL) -> Data? {
        for name in ["cover.jpg", "folder.jpg", "cover.png", "folder.png"] {
            let url = folder.appendingPathComponent(name)
            guard let resource = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]),
                  resource.isRegularFile == true, resource.isSymbolicLink != true,
                  (resource.fileSize ?? Int.max) <= 10_000_000 else { continue }
            if resource.isUbiquitousItem == true && resource.ubiquitousItemDownloadingStatus != .current && resource.ubiquitousItemDownloadingStatus != .downloaded { continue }
            if let data = try? Data(contentsOf: url),
               let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
               CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 1] as CFDictionary) != nil { return data }
        }
        return nil
    }
}
