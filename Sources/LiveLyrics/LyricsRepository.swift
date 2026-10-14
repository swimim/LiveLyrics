import Foundation

struct LRCLIBRecord: Decodable, Sendable {
    var id: Int
    var trackName: String
    var artistName: String
    var albumName: String
    var duration: Double
    var instrumental: Bool
    var plainLyrics: String?
    var syncedLyrics: String?
}

enum LyricsError: Error, LocalizedError {
    case contactRequired, invalidInput, notFound, mismatch, invalidResponse, http(Int), rateLimited(Date)
    var errorDescription: String? {
        switch self {
        case .contactRequired: return "LRCLIB 연락처를 저장해 주세요. 메뉴에서 변경할 수 있어요"
        case .invalidInput: return "곡 정보를 확인하고 있어요"
        case .notFound: return "가사를 찾지 못했어요"
        case .mismatch: return "곡 확인이 필요해요"
        case .invalidResponse: return "가사 형식을 읽을 수 없어요"
        case .http(let code): return "가사를 불러오지 못했어요 (HTTP \(code))"
        case .rateLimited(let date): return "잠시 후 다시 시도해 주세요 (\(date.formatted(date: .omitted, time: .standard)))"
        }
    }
}

actor LyricsRepository {
    private let session: URLSession
    private var busy = false
    private var nextRequest = Date.distantPast
    private var cache: [String: (document: LyricsDocument?, expires: Date, used: Date)] = [:]
    private let spacing: Double
    init(session: URLSession? = nil, spacing: Double = 0.3) {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 15
        self.session = session ?? URLSession(configuration: config)
        self.spacing = spacing
    }
    static func validContact(_ value: String) -> Bool {
        let value = value.trimmed
        guard !value.contains(where: { $0.isWhitespace }), !value.contains("\r"), !value.contains("\n") else { return false }
        if let url = URL(string: value), ["https", "http"].contains(url.scheme ?? ""), let host = url.host, host.contains(".") { return true }
        return value.range(
            of: #"^[-A-Z0-9._%+]+@[-A-Z0-9.]+[.][A-Z]{2,}$"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }
    static func request(for track: TrackMetadata, contact: String) throws -> URLRequest {
        guard track.isQueryable else { throw LyricsError.invalidInput }
        guard validContact(contact) else { throw LyricsError.contactRequired }
        var components = URLComponents(string: "https://lrclib.net/api/get")!
        var items = [URLQueryItem(name: "track_name", value: track.title.trimmed), URLQueryItem(name: "artist_name", value: track.artist.trimmed)]
        if !track.album.trimmed.isEmpty { items.append(.init(name: "album_name", value: track.album.trimmed)) }
        if let duration = track.duration, duration.isFinite, (1...3600).contains(duration) { items.append(.init(name: "duration", value: String(duration))) }
        components.queryItems = items
        var request = URLRequest(url: components.url!)
        request.setValue("LiveLyrics/1.0 (\(contact.trimmed))", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }
    static func retryDelay(_ header: String?, now: Date = Date()) -> Double? {
        guard let header else { return nil }
        if let seconds = Double(header), seconds.isFinite { return max(0, seconds) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: header).map { max(0, $0.timeIntervalSince(now)) }
    }
    private func waitUntilAllowed() async throws {
        while Date() < nextRequest {
            try await Task.sleep(for: .seconds(min(1, nextRequest.timeIntervalSinceNow)))
        }
        try Task.checkCancellation()
    }
    func fetch(_ track: TrackMetadata, contact: String, refresh: Bool = false) async throws -> LyricsDocument {
        let request = try Self.request(for: track, contact: contact)
        // Actor reentrancy alone does not serialize requests across URLSession awaits.
        while busy { try await Task.sleep(for: .milliseconds(20)) }
        try Task.checkCancellation()
        busy = true
        defer { busy = false }
        if !refresh, let entry = cache[track.key], entry.expires > Date() {
            cache[track.key]?.used = Date()
            guard let document = entry.document else { throw LyricsError.notFound }
            return document
        }
        for attempt in 0...2 {
            try await waitUntilAllowed()
            do {
                let (data, response) = try await session.data(for: request)
                nextRequest = max(nextRequest, Date().addingTimeInterval(spacing))
                guard let http = response as? HTTPURLResponse else { throw LyricsError.invalidResponse }
                if http.statusCode == 429 || http.statusCode == 503 {
                    let delay = Self.retryDelay(http.value(forHTTPHeaderField: "Retry-After")) ?? (attempt == 0 ? 1 : 3)
                    nextRequest = max(nextRequest, Date().addingTimeInterval(delay))
                    if attempt < 2 { continue }
                    throw LyricsError.rateLimited(nextRequest)
                }
                if http.statusCode == 404 {
                    save(nil, key: track.key, lifetime: 600)
                    throw LyricsError.notFound
                }
                if (500...599).contains(http.statusCode), attempt < 2 {
                    nextRequest = Date().addingTimeInterval(attempt == 0 ? 1 : 3); continue
                }
                guard http.statusCode == 200 else { throw LyricsError.http(http.statusCode) }
                guard data.count <= 2_097_152, http.mimeType?.lowercased() == "application/json" else { throw LyricsError.invalidResponse }
                guard let record = try? JSONDecoder().decode(LRCLIBRecord.self, from: data) else { throw LyricsError.invalidResponse }
                guard record.trackName.normalized == track.title.normalized,
                      record.artistName.normalized == track.artist.normalized,
                      track.album.trimmed.isEmpty || record.albumName.normalized == track.album.normalized,
                      track.duration.map({ !$0.isFinite || $0 <= 0 || abs(record.duration - $0) <= 2 }) ?? true else { throw LyricsError.mismatch }
                var document = LyricsDocument(plain: record.plainLyrics, instrumental: record.instrumental)
                if !record.instrumental, let lrc = record.syncedLyrics, !lrc.isEmpty {
                    do { document = try LRCParser.parse(lrc); document.plain = record.plainLyrics }
                    catch { if record.plainLyrics?.trimmed.isEmpty != false { throw LyricsError.invalidResponse } }
                }
                if !document.instrumental && document.cues.isEmpty && document.plain?.trimmed.isEmpty != false {
                    if document.invalidLines > 0 { throw LyricsError.invalidResponse }
                    save(nil, key: track.key, lifetime: 600)
                    throw LyricsError.notFound
                }
                try Task.checkCancellation()
                save(document, key: track.key, lifetime: 24 * 3600)
                return document
            } catch let error as URLError {
                nextRequest = max(nextRequest, Date().addingTimeInterval(spacing))
                if Task.isCancelled || error.code == .cancelled { throw CancellationError() }
                guard attempt < 2 else { throw error }
                nextRequest = Date().addingTimeInterval(attempt == 0 ? 1 : 3)
            }
        }
        throw LyricsError.invalidResponse
    }
    private func save(_ document: LyricsDocument?, key: String, lifetime: Double) {
        cache[key] = (document, Date().addingTimeInterval(lifetime), Date())
        if cache.count > 100, let oldest = cache.min(by: { $0.value.used < $1.value.used })?.key { cache.removeValue(forKey: oldest) }
    }
}
