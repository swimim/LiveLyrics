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
        case .contactRequired: return "LRCLIB 앱 식별 정보를 확인할 수 없어요"
        case .invalidInput: return "곡 정보를 확인하고 있어요"
        case .notFound: return "가사를 찾지 못했어요"
        case .mismatch: return "곡 확인이 필요해요"
        case .invalidResponse: return "가사 형식을 읽을 수 없어요"
        case .http(let code): return "가사를 불러오지 못했어요 (HTTP \(code))"
        case .rateLimited: return "잠시 후 다시 시도해 주세요"
        }
    }
}

actor LyricsRepository {
    private let session: URLSession
    private var fallbackCooldowns: [String: Date] = [:]
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
        do {
            let document = try await fetchExact(track, request: request)
            save(document, key: track.key, lifetime: 24 * 3600)
            return document
        } catch LyricsError.notFound {
            return try await fetchFallbacks(track, contact: contact)
        } catch LyricsError.mismatch {
            return try await fetchFallbacks(track, contact: contact)
        }
    }

    private func fetchExact(_ track: TrackMetadata, request: URLRequest) async throws -> LyricsDocument {
        for attempt in 0...2 {
            try await waitUntilAllowed()
            do {
                let (data, response) = try await session.data(for: request)
                nextRequest = max(nextRequest, Date().addingTimeInterval(spacing))
                guard let http = response as? HTTPURLResponse else { throw LyricsError.invalidResponse }
                if http.statusCode == 429 || http.statusCode == 503 {
                    let delay = max(1, Self.retryDelay(http.value(forHTTPHeaderField: "Retry-After")) ?? 1)
                    nextRequest = max(nextRequest, Date().addingTimeInterval(delay))
                    if attempt < 2 { continue }
                    throw LyricsError.rateLimited(nextRequest)
                }
                if http.statusCode == 404 {
                    throw LyricsError.notFound
                }
                if (500...599).contains(http.statusCode), attempt < 2 {
                    nextRequest = Date().addingTimeInterval(1); continue
                }
                guard http.statusCode == 200 else { throw LyricsError.http(http.statusCode) }
                guard data.count <= 2_097_152, http.mimeType?.lowercased() == "application/json" else { throw LyricsError.invalidResponse }
                guard let record = try? JSONDecoder().decode(LRCLIBRecord.self, from: data) else { throw LyricsError.invalidResponse }
                guard record.trackName.normalized == track.title.normalized,
                      record.artistName.normalized == track.artist.normalized,
                      track.album.trimmed.isEmpty || record.albumName.normalized == track.album.normalized,
                      track.duration.map({ !$0.isFinite || $0 <= 0 || abs(record.duration - $0) <= 2 }) ?? true else { throw LyricsError.mismatch }
                let document = try Self.document(from: record)
                try Task.checkCancellation()
                return document
            } catch let error as URLError {
                nextRequest = max(nextRequest, Date().addingTimeInterval(spacing))
                if Task.isCancelled || error.code == .cancelled { throw CancellationError() }
                guard attempt < 2 else { throw error }
                nextRequest = Date().addingTimeInterval(1)
            }
        }
        throw LyricsError.invalidResponse
    }
    private static func document(from record: LRCLIBRecord) throws -> LyricsDocument {
        var document = LyricsDocument(plain: record.plainLyrics, instrumental: record.instrumental)
        if !record.instrumental, let lrc = record.syncedLyrics, !lrc.isEmpty {
            do { document = try LRCParser.parse(lrc); document.plain = record.plainLyrics }
            catch { if record.plainLyrics?.trimmed.isEmpty != false { throw LyricsError.invalidResponse } }
        }
        if !document.instrumental && document.cues.isEmpty && document.plain?.trimmed.isEmpty != false {
            if document.invalidLines > 0 { throw LyricsError.invalidResponse }
            throw LyricsError.notFound
        }
        return document
    }

    static func searchRequest(for track: TrackMetadata, contact: String) throws -> URLRequest {
        var request = try request(for: track, contact: contact)
        var url = URLComponents(string: "https://lrclib.net/api/search")!
        url.queryItems = [URLQueryItem(name: "track_name", value: track.title.trimmed),
                          URLQueryItem(name: "artist_name", value: track.artist.trimmed)]
        request.url = url.url
        return request
    }

    static func alternativeRequest(for track: TrackMetadata) -> URLRequest {
        // Encode each path segment separately, including slashes and query delimiters.
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let artist = track.artist.trimmed.addingPercentEncoding(withAllowedCharacters: allowed)!
        let title = track.title.trimmed.addingPercentEncoding(withAllowedCharacters: allowed)!
        var request = URLRequest(url: URL(string: "https://api.lyrics.ovh/v1/\(artist)/\(title)")!)
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func fallbackData(for request: URLRequest) async throws -> Data {
        let host = request.url!.host!
        if let until = fallbackCooldowns[host], until > Date() { throw LyricsError.rateLimited(until) }
        try await waitUntilAllowed()
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        nextRequest = max(nextRequest, Date().addingTimeInterval(spacing))
        guard let http = response as? HTTPURLResponse else { throw LyricsError.invalidResponse }
        if http.statusCode == 404 { throw LyricsError.notFound }
        if http.statusCode == 429 || http.statusCode == 503 {
            // Do not delay the other provider because this one is unavailable.
            let until = Date().addingTimeInterval(
                max(1, Self.retryDelay(http.value(forHTTPHeaderField: "Retry-After")) ?? 1))
            fallbackCooldowns[host] = until
            throw LyricsError.rateLimited(until)
        }
        guard http.statusCode == 200 else { throw LyricsError.http(http.statusCode) }
        guard data.count <= 2_097_152, http.mimeType?.lowercased() == "application/json" else {
            throw LyricsError.invalidResponse
        }
        return data
    }

    private func fetchFallbacks(_ track: TrackMetadata, contact: String) async throws -> LyricsDocument {
        var searchFailure: Error?
        do {
            let data = try await fallbackData(for: Self.searchRequest(for: track, contact: contact))
            guard let records = try? JSONDecoder().decode([LRCLIBRecord].self, from: data) else {
                throw LyricsError.invalidResponse
            }
            // Album editions may differ, but never discard live/remix qualifiers in titles.
            // Keep the duration guard to avoid displaying incorrectly timed lyrics.
            let candidates = records.filter { record in
                record.trackName.normalized == track.title.normalized &&
                record.artistName.normalized == track.artist.normalized &&
                (track.duration.map { duration in
                    !duration.isFinite || duration <= 0 || abs(record.duration - duration) <= 2
                } ?? true)
            }.sorted {
                let left = ($0.syncedLyrics?.trimmed.isEmpty == false ? 2 : 0) +
                    ($0.albumName.normalized == track.album.normalized ? 1 : 0)
                let right = ($1.syncedLyrics?.trimmed.isEmpty == false ? 2 : 0) +
                    ($1.albumName.normalized == track.album.normalized ? 1 : 0)
                return left > right
            }
            for record in candidates {
                if let document = try? Self.document(from: record) {
                    try Task.checkCancellation()
                    save(document, key: track.key, lifetime: 24 * 3600)
                    return document
                }
            }
        } catch {
            try Task.checkCancellation()
            if (error as? URLError)?.code == .cancelled { throw CancellationError() }
            if case LyricsError.notFound = error { } else { searchFailure = error }
        }
        do {
            struct Response: Decodable { let lyrics: String }
            let data = try await fallbackData(for: Self.alternativeRequest(for: track))
            guard let response = try? JSONDecoder().decode(Response.self, from: data) else {
                throw LyricsError.invalidResponse
            }
            guard !response.lyrics.trimmed.isEmpty else { throw LyricsError.notFound }
            let document = LyricsDocument(plain: response.lyrics.trimmed)
            try Task.checkCancellation()
            save(document, key: track.key, lifetime: 24 * 3600)
            return document
        } catch LyricsError.notFound {
            // A failed provider is not proof that the song has no lyrics.
            if let searchFailure { throw searchFailure }
            save(nil, key: track.key, lifetime: 600)
            throw LyricsError.notFound
        } catch {
            try Task.checkCancellation()
            if (error as? URLError)?.code == .cancelled { throw CancellationError() }
            throw error
        }
    }
    private func save(_ document: LyricsDocument?, key: String, lifetime: Double) {
        cache[key] = (document, Date().addingTimeInterval(lifetime), Date())
        if cache.count > 100, let oldest = cache.min(by: { $0.value.used < $1.value.used })?.key { cache.removeValue(forKey: oldest) }
    }
}
