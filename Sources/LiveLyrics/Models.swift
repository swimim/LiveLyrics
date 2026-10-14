import Foundation

struct TrackMetadata: Equatable, Sendable {
    var source: String
    var sourceID: String? = nil
    var title: String
    var artist: String
    var album: String = ""
    var duration: Double? = nil
    var key: String {
        // Include metadata revisions, but never playback position.
        [source, sourceID ?? "", title, artist, album,
         duration.flatMap { $0.isFinite ? String($0.rounded()) : nil } ?? ""]
            .map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
    }
    var isQueryable: Bool { !title.trimmed.isEmpty && !artist.trimmed.isEmpty }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
    var normalized: String {
        precomposedStringWithCanonicalMapping.lowercased()
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

enum PlaybackState: Sendable { case playing, paused, stopped, unknown }
struct PlaybackSnapshot: Sendable {
    var track: TrackMetadata?
    var elapsed: Double?
    var anchor: Double = ProcessInfo.processInfo.systemUptime
    var rate: Double = 1
    var state: PlaybackState
}

struct PlaybackClock {
    var snapshot: PlaybackSnapshot?
    func position(at now: Double = ProcessInfo.processInfo.systemUptime) -> Double? {
        guard let s = snapshot, let p = s.elapsed, p.isFinite else { return nil }
        let delta = s.state == .playing && s.rate.isFinite ? max(0, now - s.anchor) * max(0, s.rate) : 0
        let position = max(0, p + delta)
        if let duration = s.track?.duration, duration.isFinite, duration > 0 { return min(duration, position) }
        return position
    }
}

struct LyricCue: Identifiable, Equatable, Sendable {
    let id: Int
    let start: Double
    var texts: [String]
    var text: String { texts.joined(separator: "\n") }
}
struct LyricsDocument: Equatable, Sendable {
    var cues: [LyricCue] = []
    var plain: String? = nil
    var offsetMS: Int = 0
    var instrumental = false
    var invalidLines = 0
}

enum LyricsState: Equatable {
    case idle, loading, synced, plain, instrumental, notFound, needsSelection, failed(String)
    var message: String {
        switch self {
        case .idle: return "재생 중인 곡이 없어요"
        case .loading: return "가사를 찾고 있어요"
        case .synced: return "실시간 가사 연결됨"
        case .plain: return "동기화 정보가 없는 가사예요"
        case .instrumental: return "연주곡이에요"
        case .notFound: return "가사를 찾지 못했어요"
        case .needsSelection: return "곡 확인이 필요해요"
        case .failed(let message): return message
        }
    }
}

struct RequestGeneration {
    private(set) var value = 0
    private(set) var key: String?
    mutating func begin(_ key: String?) -> Int { value += 1; self.key = key; return value }
    func accepts(_ value: Int, key: String) -> Bool { self.value == value && self.key == key }
}

enum LyricsSynchronizer {
    static func index(in document: LyricsDocument, position: Double) -> Int? {
        guard position.isFinite else { return nil }
        let time = position + Double(document.offsetMS) / 1000
        var low = 0, high = document.cues.count
        while low < high {
            let mid = (low + high) / 2
            if document.cues[mid].start <= time { low = mid + 1 } else { high = mid }
        }
        return low == 0 ? nil : low - 1
    }
}
