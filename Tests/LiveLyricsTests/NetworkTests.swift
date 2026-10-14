import Testing
import Foundation
@testable import LiveLyrics

final class StubProtocol: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    static var responses: [(Int, [String: String], Data)] = []
    static var count = 0
    static var times: [Date] = []
    static func configure(_ items: [(Int, [String: String], Data)]) { lock.lock(); defer { lock.unlock() }; responses = items; count = 0; times = [] }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        Self.count += 1; Self.times.append(Date())
        let item = Self.responses.isEmpty ? (500, [:], Data()) : Self.responses.removeFirst()
        Self.lock.unlock()
        let response = HTTPURLResponse(url: request.url!, statusCode: item.0, httpVersion: "HTTP/1.1", headerFields: item.1)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: item.2)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}

@Suite(.serialized) final class NetworkTests {
    let track = TrackMetadata(source: "test", title: "Synthetic", artist: "Test", duration: 120)
    let contact = "https://example.org/test-only"
    var record: Data { Data(#"{"id":1,"trackName":"Synthetic","artistName":"Test","albumName":"","duration":120,"instrumental":false,"plainLyrics":null,"syncedLyrics":"[00:01]Synthetic line\n[00:10]","extraField":true}"#.utf8) }
    func repository() -> LyricsRepository {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        return LyricsRepository(session: URLSession(configuration: config), spacing: 0.01)
    }
    @Test func testDecodeCacheAndNoPositionRequests() async throws {
        StubProtocol.configure([(200, ["Content-Type": "application/json"], record)])
        let repo = repository()
        let first = try await repo.fetch(track, contact: contact)
        let second = try await repo.fetch(track, contact: contact)
        XCTAssertEqual(first, second); XCTAssertEqual(first.cues.count, 2)
        XCTAssertEqual(StubProtocol.count, 1)
    }
    @Test func test404NegativeCacheAndNonJSONBody() async {
        StubProtocol.configure([(404, ["Content-Type": "text/html"], Data("Not Found".utf8))])
        let repo = repository()
        for _ in 0..<2 {
            do { _ = try await repo.fetch(track, contact: contact); XCTFail("Expected 404") }
            catch LyricsError.notFound { }
            catch { XCTFail("Unexpected \(error)") }
        }
        XCTAssertEqual(StubProtocol.count, 1)
    }
    @Test func test429HonorsDelayAndIgnoresHTML() async throws {
        StubProtocol.configure([(429, ["Retry-After": "0.1"], Data("<html>limited</html>".utf8)), (200, ["Content-Type": "application/json"], record)])
        _ = try await repository().fetch(track, contact: contact)
        XCTAssertEqual(StubProtocol.count, 2)
        XCTAssertGreaterThanOrEqual(StubProtocol.times[1].timeIntervalSince(StubProtocol.times[0]), 0.095)
    }
    @Test func test400NeverRetries() async {
        StubProtocol.configure([(400, [:], Data())])
        do { _ = try await repository().fetch(track, contact: contact); XCTFail() }
        catch LyricsError.http(400) { }
        catch { XCTFail("Unexpected \(error)") }
        XCTAssertEqual(StubProtocol.count, 1)
    }
    @Test func testVersionMismatchIsNotDisplayed() async {
        let mismatch = Data(String(data: record, encoding: .utf8)!.replacingOccurrences(of: "\"Synthetic\"", with: "\"Synthetic (Live)\"").utf8)
        StubProtocol.configure([(200, ["Content-Type": "application/json"], mismatch)])
        do { _ = try await repository().fetch(track, contact: contact); XCTFail() }
        catch LyricsError.mismatch { }
        catch { XCTFail("Unexpected \(error)") }
    }
    @Test func testInstrumentalAndNullLyrics() async throws {
        let instrumental = Data(#"{"id":2,"trackName":"Synthetic","artistName":"Test","albumName":"","duration":120,"instrumental":true,"plainLyrics":null,"syncedLyrics":null}"#.utf8)
        StubProtocol.configure([(200, ["Content-Type": "application/json"], instrumental)])
        let result = try await repository().fetch(track, contact: contact)
        XCTAssertTrue(result.instrumental); XCTAssertTrue(result.cues.isEmpty)
    }
    @Test func testCancelledQueuedRequestNeverStarts() async throws {
        StubProtocol.configure([(429, ["Retry-After": "0.15"], Data()), (200, ["Content-Type": "application/json"], record)])
        let repo = repository()
        let first = Task { try await repo.fetch(track, contact: contact) }
        try await Task.sleep(for: .milliseconds(30))
        let second = Task { try await repo.fetch(track, contact: contact, refresh: true) }
        second.cancel()
        _ = try await first.value
        do { _ = try await second.value; XCTFail() } catch is CancellationError { }
        XCTAssertEqual(StubProtocol.count, 2)
    }
    @Test func test503ThenSuccessAndMalformedJSON() async throws {
        StubProtocol.configure([(503, ["Retry-After": "0.01"], Data()), (200, ["Content-Type": "application/json"], record)])
        _ = try await repository().fetch(track, contact: contact)
        XCTAssertEqual(StubProtocol.count, 2)
        StubProtocol.configure([(200, ["Content-Type": "application/json"], Data("broken".utf8))])
        do { _ = try await repository().fetch(track, contact: contact); XCTFail() }
        catch LyricsError.invalidResponse { }
        catch { XCTFail("Unexpected \(error)") }
    }
    @Test @MainActor func testRapidABAOnlyAppliesLatestTrackAndNoSessionClears() async throws {
        StubProtocol.configure([(200, ["Content-Type": "application/json"], record)])
        let model = AppModel(repository: repository())
        model.contact = contact
        var a = track; a.sourceID = "A"
        var b = track; b.sourceID = "B"
        model.receive(PlaybackSnapshot(track: a, elapsed: 5, state: .paused))
        model.receive(PlaybackSnapshot(track: b, elapsed: 9, state: .paused))
        model.receive(PlaybackSnapshot(track: a, elapsed: 3, state: .paused))
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(model.track?.sourceID, "A")
        XCTAssertEqual(model.lyricsState, .synced)
        XCTAssertEqual(model.activeIndex, 0)
        XCTAssertEqual(StubProtocol.count, 1)
        model.receive(PlaybackSnapshot(track: a, elapsed: 0, state: .paused))
        XCTAssertNil(model.activeIndex)
        XCTAssertTrue(model.isBeforeFirstLyric)
        XCTAssertEqual(model.displayedLyricIndex, 0)
        XCTAssertTrue(model.hasDisplayableLyrics)
        model.receive(PlaybackSnapshot(track: a, elapsed: 3, state: .paused))
        model.receive(PlaybackSnapshot(track: a, elapsed: 11, state: .paused))
        XCTAssertTrue(model.isLyricsFinished)
        XCTAssertEqual(model.displayedLyricIndex, 0)
        XCTAssertTrue(model.hasDisplayableLyrics)
        model.receive(PlaybackSnapshot(track: nil, elapsed: nil, state: .unknown))
        XCTAssertEqual(model.track?.sourceID, "A")
        XCTAssertEqual(model.document.cues.count, 2)
        model.receive(PlaybackSnapshot(track: nil, elapsed: 10, state: .stopped))
        XCTAssertEqual(model.track?.sourceID, "A")
        XCTAssertEqual(model.document.cues.count, 2)
        model.receive(PlaybackSnapshot(track: nil, elapsed: 120, state: .stopped))
        XCTAssertTrue(model.document.cues.isEmpty)
        XCTAssertNil(model.activeIndex)
        XCTAssertEqual(model.lyricsState, .idle)
        model.stop()
    }

}
