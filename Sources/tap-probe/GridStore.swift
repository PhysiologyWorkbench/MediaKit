#if os(macOS)
import Foundation

/// A cached full-track beat analysis, one JSON file per track URI.
struct BeatGrid: Codable {
    let uri: String
    let name: String
    let artist: String
    let bpm: Double
    let confidence: Double
    let analysedAt: Date
    let frameRate: Double
    /// Beat times in seconds from track start.
    let beats: [Double]
    let duration: TimeInterval?
}

struct GridStore {
    let directory: URL

    init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
    }

    private func sanitised(_ uri: String) -> String {
        String(uri.map { $0.isLetter || $0.isNumber ? $0 : "-" })
    }

    private func file(for uri: String) -> URL {
        directory.appending(path: sanitised(uri) + ".json")
    }

    func sidecarURL(uri: String, suffix: String) -> URL {
        directory.appending(path: sanitised(uri) + "." + suffix)
    }

    func load(uri: String) -> BeatGrid? {
        guard let data = try? Data(contentsOf: file(for: uri)) else { return nil }
        return try? JSONDecoder().decode(BeatGrid.self, from: data)
    }

    func save(_ grid: BeatGrid) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(grid).write(to: file(for: grid.uri))
    }
}
#endif
