import Testing
import Foundation
@testable import LiveLyrics

@Suite(.serialized) final class CoreTests {
    @Test func testParserFractionsGroupingBOMAndCRLF() throws {
        let doc = try LRCParser.parse("\u{FEFF}[offset:-250]\r\n[00:02.123]끝\r\n[00:01.5][00:02.00]반복\n[00:01.500]함께\n[00:01.500]함께\n[00:03]\n[ar:합성]")
        XCTAssertEqual(doc.cues.map(\.start), [1.5, 2, 2.123, 3])
        XCTAssertEqual(doc.cues[0].texts, ["반복", "함께"])
        XCTAssertEqual(doc.cues[3].text, "")
        XCTAssertEqual(doc.offsetMS, -250)
    }
    @Test func testInvalidTimestampsLimitsAndEnhanced() throws {
        let doc = try LRCParser.parse("[00:60]오류\n[00:01.1234]오류\n[00:00.25]정상\n[offset:-999999999999999999999999]\n[00:xx]오류")
        XCTAssertEqual(doc.cues.count, 1)
        XCTAssertEqual(doc.invalidLines, 4)
        XCTAssertThrowsError(try LRCParser.parse(String(repeating: "a", count: 1_048_577)))
        XCTAssertThrowsError(try LRCParser.parse("[00:01]<00:01.2>단어"))
        XCTAssertThrowsError(try LRCParser.parse(String(repeating: "[00:01]줄\n", count: 10_001)))
    }
    @Test func testBoundariesAndSingleOffsetApplication() throws {
        var doc = try LRCParser.parse("[00:10]하나\n[00:20]둘\n[00:25]")
        XCTAssertNil(LyricsSynchronizer.index(in: doc, position: 9.999))
        XCTAssertEqual(LyricsSynchronizer.index(in: doc, position: 10), 0)
        XCTAssertEqual(LyricsSynchronizer.index(in: doc, position: 20), 1)
        XCTAssertEqual(LyricsSynchronizer.index(in: doc, position: 100), 2)
        doc.offsetMS = 250
        XCTAssertEqual(LyricsSynchronizer.index(in: doc, position: 9.75), 0)
        doc.offsetMS = -500
        XCTAssertNil(LyricsSynchronizer.index(in: doc, position: 10))
        doc.offsetMS = 250
        XCTAssertEqual(LyricsSynchronizer.index(in: doc, position: 10), 0) // backward seek
    }
    @Test func testClockPauseResumeSeekRateAndTenMinutes() {
        let track = TrackMetadata(source: "test", title: "t", artist: "a", duration: 1000)
        var clock = PlaybackClock(snapshot: PlaybackSnapshot(track: track, elapsed: 10, anchor: 100, rate: 1, state: .playing))
        XCTAssertEqual(clock.position(at: 700), 610)
        clock.snapshot?.state = .paused
        XCTAssertEqual(clock.position(at: 700), 10)
        clock.snapshot = PlaybackSnapshot(track: track, elapsed: 25, anchor: 700, rate: 2, state: .playing)
        XCTAssertEqual(clock.position(at: 710), 45)
        clock.snapshot?.elapsed = 3; clock.snapshot?.anchor = 710
        XCTAssertEqual(clock.position(at: 710), 3)
        XCTAssertEqual(clock.position(at: 2000), 1000)
        clock.snapshot?.elapsed = nil
        XCTAssertNil(clock.position(at: 2000))
    }
    @Test func testMediaRemoteUsesUnixMicrosOnceAndPausedOverridesRate() throws {
        let data = Data(#"{"title":"합성","artist":"테스트","bundleIdentifier":"test","elapsedTimeMicros":5000000,"timestampEpochMicros":100000000,"durationMicros":90000000,"playing":true,"playbackRate":1}"#.utf8)
        var payload = try JSONDecoder().decode(MediaRemotePayload.self, from: data)
        let clock = PlaybackClock(snapshot: payload.snapshot(epoch: 102, uptime: 50))
        XCTAssertEqual(clock.position(at: 51), 8)
        payload.playing = false
        XCTAssertEqual(PlaybackClock(snapshot: payload.snapshot(epoch: 102, uptime: 50)).position(at: 60), 5)
        payload.elapsedTimeMicros = nil
        XCTAssertNil(payload.snapshot().elapsed)
    }
    @Test func testGenerationRejectsABAAndOldResponse() {
        var gate = RequestGeneration()
        let first = gate.begin("A"), second = gate.begin("B"), third = gate.begin("A")
        XCTAssertFalse(gate.accepts(first, key: "A"))
        XCTAssertFalse(gate.accepts(second, key: "B"))
        XCTAssertTrue(gate.accepts(third, key: "A"))
        _ = gate.begin(nil)
        XCTAssertFalse(gate.accepts(third, key: "A"))
    }
    @Test @MainActor func testPanelGeometryIncludesScreenOrigin() {
        XCTAssertEqual(OverlayController.frame(in: CGRect(x: -1920, y: 100, width: 1920, height: 1080)), CGRect(x: -480, y: 370, width: 480, height: 540))
        XCTAssertEqual(OverlayController.verticalScrollOffset(viewportHeight: 400, cueCenter: 40), 0)
        XCTAssertEqual(OverlayController.verticalScrollOffset(viewportHeight: 400, cueCenter: 240), -40)
    }
    @Test func testRequestEncodingAndContactValidation() throws {
        let track = TrackMetadata(source: "test", title: "하늘 & 빛", artist: "A+B", album: "앨범", duration: 123)
        let request = try LyricsRepository.request(for: track, contact: "https://example.org/project")
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(query.first(where: { $0.name == "track_name" })?.value, "하늘 & 빛")
        XCTAssertEqual(query.first(where: { $0.name == "artist_name" })?.value, "A+B")
        XCTAssertTrue(request.value(forHTTPHeaderField: "User-Agent")!.contains("LiveLyrics/1.0"))
        XCTAssertFalse(LyricsRepository.validContact(""))
        XCTAssertTrue(LyricsRepository.validContact("author" + "@example.org"))
        XCTAssertFalse(LyricsRepository.validContact("x\r\nHeader: y"))
        XCTAssertThrowsError(try LyricsRepository.request(for: track, contact: ""))
    }
    @Test func testRetryAfterSecondsAndHTTPDate() {
        XCTAssertEqual(LyricsRepository.retryDelay("12"), 12)
        XCTAssertEqual(LyricsRepository.retryDelay("Thu, 01 Jan 1970 00:01:00 GMT", now: Date(timeIntervalSince1970: 50)), 10)
        XCTAssertNil(LyricsRepository.retryDelay("invalid"))
    }
}
