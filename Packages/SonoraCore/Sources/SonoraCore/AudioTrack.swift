import Foundation

public struct AudioTrack: Identifiable, Equatable, Codable, Sendable {
    public let relativePath: String
    public let sourceID: String?
    public let cue: CueSegment?
    public var localID: String { relativePath + (cue.map { "\0cue:\($0.sheetPath):\($0.number):\($0.startCDFrame):\($0.endCDFrame.map(String.init) ?? "end")" } ?? "") }
    public var id: String { sourceID.map { $0 + "\0" + localID } ?? localID }
    public var filename: String { (relativePath as NSString).lastPathComponent }
    public var displayName: String { cue?.tags[.title] ?? (filename as NSString).deletingPathExtension }
    public var folder: String { (relativePath as NSString).deletingLastPathComponent }

    public init?(relativePath: String, sourceID: String? = nil, cue: CueSegment? = nil) {
        let parts = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard !relativePath.isEmpty, !relativePath.hasPrefix("/"),
              !parts.contains(".."), !parts.contains("."), !parts.contains(""),
              !relativePath.contains("\0"), sourceID?.contains("\0") != true,
              cue?.isValid != false else { return nil }
        self.relativePath = relativePath
        self.sourceID = sourceID
        self.cue = cue
    }

    public func withSource(_ sourceID: String?) -> AudioTrack {
        // This value already passed path and segment validation.
        AudioTrack(relativePath: relativePath, sourceID: sourceID, cue: cue)!
    }
    public func duration(in total: Double) -> Double {
        guard let cue else { return total }
        return max(0, min(total, cue.endSeconds ?? total) - cue.startSeconds)
    }
    public func tags(overriding values: [MetadataField: String]) -> [MetadataField: String] {
        values.merging(cue?.tags ?? [:]) { _, cueValue in cueValue }
    }

    public func url(in root: URL) -> URL { root.appendingPathComponent(relativePath) }
}
