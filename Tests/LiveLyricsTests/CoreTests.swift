import Testing
import Foundation
import AppKit
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
    @Test @MainActor func testLyricsLeadAdvancesSelectionWithoutMovingPlaybackClock() throws {
        let model = AppModel()
        defer { model.stop() }
        let track = TrackMetadata(source: "test", title: "노래", artist: "가수", duration: 60)
        model.track = track
        model.document = try LRCParser.parse("[00:02]첫 줄\n[00:03]둘째 줄\n[01:00]")
        model.lyricsState = .synced
        model.receive(PlaybackSnapshot(track: track, elapsed: 0.999, state: .paused))
        XCTAssertNil(model.activeIndex)
        model.receive(PlaybackSnapshot(track: track, elapsed: 1, state: .paused))
        XCTAssertEqual(model.activeIndex, 0)
        model.receive(PlaybackSnapshot(track: track, elapsed: 1.999, state: .paused))
        XCTAssertEqual(model.activeIndex, 0)
        model.receive(PlaybackSnapshot(track: track, elapsed: 2, state: .paused))
        XCTAssertEqual(model.activeIndex, 1)
        XCTAssertEqual(model.clock.position(), 2)
        // Seeking back uses the same correction, without accumulating it.
        model.receive(PlaybackSnapshot(track: track, elapsed: 1, state: .paused))
        XCTAssertEqual(model.activeIndex, 0)
        XCTAssertEqual(model.clock.position(), 1)
        // LRC metadata offset is still applied exactly once.
        model.document.offsetMS = 250
        model.receive(PlaybackSnapshot(track: track, elapsed: 0.75, state: .paused))
        XCTAssertEqual(model.activeIndex, 0)
        model.document.offsetMS = 0
        model.receive(PlaybackSnapshot(track: track, elapsed: 59, state: .paused))
        XCTAssertEqual(model.track, track)
        XCTAssertEqual(model.clock.position(), 59)
        model.receive(PlaybackSnapshot(track: track, elapsed: 60, state: .paused))
        XCTAssertNil(model.track)
    }
    @Test @MainActor func testLyricsLeadIsConsistentAcrossPauseAndResume() throws {
        let model = AppModel()
        defer { model.stop() }
        let track = TrackMetadata(source: "test", title: "노래", artist: "가수", duration: 60)
        model.track = track
        model.document = try LRCParser.parse("[00:02]첫 줄\n[00:03]둘째 줄")
        model.lyricsState = .synced
        model.receive(PlaybackSnapshot(track: track, elapsed: 2.1, state: .playing))
        XCTAssertEqual(model.activeIndex, 1)
        model.receive(PlaybackSnapshot(track: track, elapsed: nil, state: .paused))
        XCTAssertEqual(model.activeIndex, 1)
        model.receive(PlaybackSnapshot(track: track, elapsed: nil, state: .playing))
        XCTAssertEqual(model.activeIndex, 1)
        #expect(abs((model.clock.position() ?? 0) - 2.1) < 0.1)
    }
    @Test @MainActor func testTileTransitionsKeepClockAndRevealCurrentCue() throws {
        _ = NSApplication.shared
        let model = AppModel()
        let controller = OverlayController(model: model, releaseChecker: ReleaseUpdateChecker())
        defer { controller.close(); model.stop() }
        let track = TrackMetadata(source: "test", title: "Song", artist: "Artist", duration: 120)
        model.track = track
        let document = try LRCParser.parse("[00:01]First\n[00:10]Second\n[00:20]Third")
        model.document = document
        model.lyricsState = .synced
        model.receive(PlaybackSnapshot(track: track, elapsed: 25, state: .playing))
        let original = try #require(model.clock.snapshot)
        for _ in 0..<5 {
            // Simulate a render tick delayed while the lyrics view is absent.
            model.activeIndex = 0
            controller.expand()
            XCTAssertEqual(model.activeIndex, 2)
            controller.collapse(duration: 0.1)
            XCTAssertEqual(model.clock.snapshot?.anchor, original.anchor)
            XCTAssertEqual(model.clock.snapshot?.elapsed, original.elapsed)
            XCTAssertEqual(model.document, document)
            XCTAssertEqual(model.lyricsState, .synced)
        }
        model.receive(PlaybackSnapshot(track: track, elapsed: 25, state: .paused))
        let paused = try #require(model.clock.snapshot)
        controller.expand()
        controller.collapse(duration: 0.1)
        XCTAssertEqual(model.clock.position(at: paused.anchor + 60), 25)
        XCTAssertEqual(model.activeIndex, 2)
    }
    @Test @MainActor func testPeriodicPositionCorrectsDriftWithoutReloadingLyrics() throws {
        let model = AppModel()
        defer { model.stop() }
        let track = TrackMetadata(source: "com.spotify.client", title: "Song", artist: "Artist", duration: 120)
        model.track = track
        let document = try LRCParser.parse("[00:01]First\n[00:10]Second\n[00:20]")
        model.document = document
        model.lyricsState = .synced
        model.receive(PlaybackSnapshot(track: track, elapsed: 5, state: .playing))
        let data = Data(#"{"bundleIdentifier":"com.spotify.client","title":"Song","artist":"Artist","durationMicros":120000000,"elapsedTimeMicros":11000000,"playing":true}"#.utf8)
        let update = try #require(MediaRemoteProvider.positionUpdate(data, current: model.clock.snapshot))
        model.receive(update)
        XCTAssertEqual(model.activeIndex, 1)
        XCTAssertEqual(model.document, document)
        XCTAssertEqual(model.lyricsState, .synced)
        #expect(abs((model.clock.position() ?? 0) - 11) < 0.1)
        model.receive(PlaybackSnapshot(track: track, elapsed: nil, state: .paused))
        XCTAssertNil(MediaRemoteProvider.positionUpdate(data, current: model.clock.snapshot))
        XCTAssertEqual(model.activeIndex, 1)
        XCTAssertEqual(model.document, document)
    }
    @Test @MainActor func testPeriodicPositionRejectsStaleTrackAndMissingPosition() {
        let track = TrackMetadata(source: "com.spotify.client", title: "Song", artist: "Artist")
        let current = PlaybackSnapshot(track: track, elapsed: 5, state: .playing)
        for json in [
            #"{"bundleIdentifier":"com.spotify.client","title":"Old Song","artist":"Artist","elapsedTimeMicros":1000000,"playing":true}"#,
            #"{"bundleIdentifier":"com.spotify.client","title":"Song","artist":"Artist","playing":true}"#,
            #"{"bundleIdentifier":"com.spotify.client","title":"Song","artist":"Artist","elapsedTimeMicros":1000000,"playing":false}"#,
            "null", "broken"
        ] {
            XCTAssertNil(MediaRemoteProvider.positionUpdate(Data(json.utf8), current: current))
        }
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
    @Test @MainActor func testMissingElapsedOnPauseKeepsLyricsPosition() throws {
        let model = AppModel()
        let track = TrackMetadata(source: "test", title: "노래", artist: "가수", duration: 60)
        model.track = track
        model.document = try LRCParser.parse("[00:05]첫 줄\n[00:10]둘째 줄")
        model.lyricsState = .synced
        model.receive(PlaybackSnapshot(track: track, elapsed: 10, state: .playing))
        XCTAssertTrue(model.positionKnown)
        XCTAssertEqual(model.activeIndex, 1)
        model.receive(PlaybackSnapshot(track: track, elapsed: nil, state: .paused))
        XCTAssertTrue(model.positionKnown)
        XCTAssertEqual(model.activeIndex, 1)
    }
    @Test @MainActor func testReconnectLoadingMessageSurvivesMissingMetadata() {
        let model = AppModel()
        model.lyricsState = .loading
        XCTAssertEqual(model.overlayMessage, LyricsState.loading.message)
        model.receive(PlaybackSnapshot(track: nil, elapsed: nil, state: .unknown))
        XCTAssertEqual(model.overlayMessage, LyricsState.loading.message)
        model.track = TrackMetadata(source: "test", title: "노래", artist: "가수", duration: 60)
        XCTAssertEqual(model.overlayMessage, LyricsState.loading.message)
        model.lyricsState = .notFound
        XCTAssertEqual(model.overlayMessage, LyricsState.notFound.message)
        model.stop()
    }
    @Test @MainActor func testMissingElapsedUsesFreshAnchorOnResume() throws {
        let model = AppModel()
        defer { model.stop() }
        let track = TrackMetadata(source: "test", title: "노래", artist: "가수", duration: 60)
        model.track = track
        model.document = try LRCParser.parse("[00:01]첫 줄\n[00:15]둘째 줄")
        model.lyricsState = .synced
        model.receive(PlaybackSnapshot(track: track, elapsed: 10, state: .paused))
        model.receive(PlaybackSnapshot(track: track, elapsed: nil,
                                       anchor: ProcessInfo.processInfo.systemUptime - 10, state: .playing))
        let position = try #require(model.clock.position())
        #expect(position >= 10 && position < 10.2)
        XCTAssertEqual(model.activeIndex, 0)
    }
    @Test @MainActor func testResumeWithPartialMetadataKeepsLoadedLyrics() throws {
        let model = AppModel()
        defer { model.stop() }
        let track = TrackMetadata(source: "test", sourceID: "song-a", title: "노래", artist: "가수", album: "앨범", duration: 60)
        let document = try LRCParser.parse("[00:01]첫 줄\n[00:15]둘째 줄")
        model.track = track
        model.document = document
        model.lyricsState = .synced
        model.receive(PlaybackSnapshot(track: track, elapsed: 20, state: .paused))
        let partial = TrackMetadata(source: "test", title: "노래", artist: "가수")
        model.receive(PlaybackSnapshot(track: partial, elapsed: nil, state: .playing))
        XCTAssertEqual(model.track?.key, track.key)
        XCTAssertEqual(model.document, document)
        XCTAssertEqual(model.lyricsState, .synced)
        XCTAssertEqual(model.activeIndex, 1)
        XCTAssertTrue(model.hasDisplayableLyrics)
        var different = track
        different.sourceID = "song-b"
        XCTAssertFalse(different.isSameRecording(as: track))
        different = track
        different.title = "다른 곡"
        XCTAssertFalse(different.isSameRecording(as: track))
    }
    @Test @MainActor func testStateOnlyPauseResumePreservesHighlightAndInstrumental() throws {
        let model = AppModel()
        defer { model.stop() }
        let epoch = Date().timeIntervalSince1970
        var payload = try JSONDecoder().decode(MediaRemotePayload.self, from: Data(#"{"bundleIdentifier":"test","title":"Song","artist":"Artist","uniqueIdentifier":"song-a","durationMicros":120000000,"elapsedTimeMicros":0,"playing":true,"playbackRate":1}"#.utf8))
        payload.timestampEpochMicros = (epoch - 20) * 1_000_000
        let first = payload.snapshot(epoch: epoch)
        model.track = first.track
        let key = model.track?.key
        let document = try LRCParser.parse("[00:01]첫 줄\n[00:10]현재 줄\n[00:30]\n[00:45]다음 줄")
        model.document = document
        model.lyricsState = .synced
        model.receive(first)
        XCTAssertEqual(model.activeIndex, 1)

        // Pause only changes the state; raw elapsed is still zero.
        payload.playing = false
        model.receive(payload.snapshot(epoch: epoch))
        XCTAssertEqual(model.activeIndex, 1)
        XCTAssertFalse(model.isBeforeFirstLyric)
        XCTAssertTrue(model.hasDisplayableLyrics)
        XCTAssertNil(model.overlayMessage)

        // A metadata-only pause event must not replace the song or the anchor.
        let partial = TrackMetadata(source: "test", sourceID: "song-a", title: "", artist: "")
        model.receive(PlaybackSnapshot(track: partial, elapsed: nil, state: .paused))
        XCTAssertEqual(model.track?.key, key)
        XCTAssertEqual(model.activeIndex, 1)

        // The provider's timestamp still predates a long pause. Do not add it.
        payload.playing = true
        payload.title = nil
        payload.artist = nil
        model.receive(payload.snapshot(epoch: epoch + 15))
        XCTAssertEqual(model.activeIndex, 1)
        XCTAssertEqual(model.document, document)
        XCTAssertEqual(model.lyricsState, .synced)
        XCTAssertTrue(model.hasDisplayableLyrics)
        XCTAssertNil(model.overlayMessage)
        #expect(try #require(model.clock.position()) < 21)

        // A genuinely new position anchor still permits seeking into an interlude.
        payload.elapsedTimeMicros = 35_000_000
        payload.timestampEpochMicros = epoch * 1_000_000
        model.receive(payload.snapshot(epoch: epoch))
        XCTAssertEqual(model.activeIndex, 2)
        payload.playing = false
        model.receive(payload.snapshot(epoch: epoch))
        XCTAssertEqual(model.activeIndex, 2)
        payload.playing = true
        model.receive(payload.snapshot(epoch: epoch + 20))
        XCTAssertEqual(model.activeIndex, 2)
        XCTAssertTrue(model.hasDisplayableLyrics)
        XCTAssertEqual(model.document, document)

        // A real seek back to the start must still work.
        payload.elapsedTimeMicros = 0
        payload.timestampEpochMicros = (epoch + 21) * 1_000_000
        model.receive(payload.snapshot(epoch: epoch + 21))
        XCTAssertEqual(model.activeIndex, 0) // The first cue at 1s is displayed at 0s.
    }
    @Test @MainActor func testRepeatedResumeWithStaleZeroRateKeepsClockMoving() throws {
        let model = AppModel()
        defer { model.stop() }
        var payload = try JSONDecoder().decode(MediaRemotePayload.self, from: Data(#"{"bundleIdentifier":"test","title":"Song","artist":"Artist","elapsedTimeMicros":10000000,"timestampEpochMicros":100000000,"playing":true,"playbackRate":1}"#.utf8))
        model.track = payload.snapshot(epoch: 100).track
        model.document = try LRCParser.parse("[00:01]First\n[00:20]Second")
        model.lyricsState = .synced
        model.receive(payload.snapshot(epoch: 100))
        for _ in 0..<20 {
            payload.playing = false; payload.playbackRate = 0
            model.receive(payload.snapshot(epoch: 100))
            let paused = try #require(model.clock.snapshot)
            XCTAssertEqual(model.clock.position(at: paused.anchor + 30), paused.elapsed)
            payload.playing = true // State arrives before the updated rate.
            model.receive(payload.snapshot(epoch: 130))
            let resumed = try #require(model.clock.snapshot)
            #expect(abs((model.clock.position(at: resumed.anchor + 1) ?? 0) - (resumed.elapsed ?? 0) - 1) < 0.001)
            #expect((resumed.elapsed ?? 0) < 11)
            XCTAssertEqual(model.lyricsState, .synced)
            XCTAssertEqual(model.activeIndex, 0)
        }
    }
    @Test @MainActor func testOlderPositionAnchorCannotUndoResumeCorrection() throws {
        let model = AppModel()
        defer { model.stop() }
        let track = TrackMetadata(source: "test", title: "Song", artist: "Artist")
        model.track = track
        model.document = try LRCParser.parse("[00:01]First\n[00:20]Second")
        model.lyricsState = .synced
        model.receive(PlaybackSnapshot(track: track, elapsed: 25, state: .playing,
                                       positionReference: .init(elapsed: 25, timestamp: 200)))
        model.receive(PlaybackSnapshot(track: track, elapsed: 5, state: .playing,
                                       positionReference: .init(elapsed: 5, timestamp: 100)))
        #expect(abs((model.clock.position() ?? 0) - 25) < 0.1)
        XCTAssertEqual(model.activeIndex, 1)
        // Backward seeking is valid when its source timestamp is newer.
        model.receive(PlaybackSnapshot(track: track, elapsed: 3, state: .playing,
                                       positionReference: .init(elapsed: 3, timestamp: 201)))
        #expect(abs((model.clock.position() ?? 0) - 3) < 0.1)
        XCTAssertEqual(model.activeIndex, 0)
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
        XCTAssertEqual(OverlayController.frame(in: CGRect(x: -1920, y: 100, width: 1920, height: 1080)), CGRect(x: -422.4, y: 370, width: 422.4, height: 540))
        XCTAssertEqual(OverlayController.statusFrame(in: CGRect(x: 0, y: 0, width: 1440, height: 900)), CGRect(x: 1123.2, y: 225, width: 316.8, height: 450))
        XCTAssertEqual(OverlayController.frame(in: CGRect(x: 0, y: 0, width: 1440, height: 900), showingLyrics: false), OverlayController.statusFrame(in: CGRect(x: 0, y: 0, width: 1440, height: 900)))
        XCTAssertEqual(OverlayController.collapsedFrame(in: CGRect(x: 0, y: 0, width: 1440, height: 900)), CGRect(x: 1370, y: 415, width: 70, height: 70))
        XCTAssertEqual(OverlayController.collapsedFrame(in: CGRect(x: -1920, y: 100, width: 1920, height: 1080)), CGRect(x: -70, y: 605, width: 70, height: 70))
        XCTAssertEqual(OverlayController.collapsedFrame(in: CGRect(x: 0, y: 0, width: 1440, height: 900), verticalFraction: 0).minY, 0)
        XCTAssertEqual(OverlayController.collapsedFrame(in: CGRect(x: 0, y: 0, width: 1440, height: 900), verticalFraction: 1).maxY, 900)
        let menuBarSafeArea = CGRect(x: 0, y: 0, width: 1440, height: 870)
        XCTAssertEqual(OverlayController.frame(in: menuBarSafeArea, verticalFraction: 1).maxY, menuBarSafeArea.maxY)
        XCTAssertEqual(OverlayController.collapsedFrame(in: menuBarSafeArea, verticalFraction: 1).maxY, menuBarSafeArea.maxY)
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        XCTAssertEqual(OverlayController.frame(in: screen, showingLyrics: false, verticalFraction: 0.8),
                       OverlayController.frame(in: screen, showingLyrics: true, verticalFraction: 0.8))
        XCTAssertEqual(OverlayController.frame(in: screen, verticalFraction: 0.25).midY,
                       OverlayController.collapsedFrame(in: screen, verticalFraction: 0.25).midY)
        XCTAssertEqual(OverlayController.verticalScrollOffset(viewportHeight: 400, cueCenter: 40), 0)
        XCTAssertEqual(OverlayController.verticalScrollOffset(viewportHeight: 400, cueCenter: 240), -40)
        XCTAssertEqual(OverlayController.lyricsOffset(viewportHeight: 400, contentHeight: 800, cueCenter: 200, manualOffset: -500), -400)
        XCTAssertEqual(OverlayController.lyricsOffset(viewportHeight: 400, contentHeight: 800, cueCenter: 200, manualOffset: 500), 0)
        XCTAssertEqual(OverlayController.lyricsOffset(viewportHeight: 400, contentHeight: 300, cueCenter: 150, manualOffset: -100), 0)
        let panel = CGRect(x: 100, y: 200, width: 420, height: 540)
        #expect(OverlayController.isInsideLyricsViewport(CGPoint(x: 200, y: 300), panelFrame: panel))
        #expect(!OverlayController.isInsideLyricsViewport(CGPoint(x: 200, y: 710), panelFrame: panel))
        #expect(!OverlayController.isInsideLyricsViewport(CGPoint(x: 99, y: 300), panelFrame: panel))
        #expect(!OverlayController.isInsideLyricsViewport(CGPoint(x: 200, y: 220), panelFrame: panel))
    }
    @Test @MainActor func testLyricsDragSharesTileBoundsAndKeepsGrabOffset() {
        let screen = CGRect(x: -1440, y: 100, width: 1440, height: 870)
        for frame in [OverlayController.frame(in: screen), OverlayController.collapsedFrame(in: screen)] {
            let bottom = OverlayController.draggedFrame(frame, in: screen, pointerY: -5000, pointerOffsetY: 20)
            let top = OverlayController.draggedFrame(frame, in: screen, pointerY: 5000, pointerOffsetY: 20)
            XCTAssertEqual(bottom.minY, screen.minY)
            XCTAssertEqual(top.maxY, screen.maxY)
            XCTAssertEqual(top.maxX, screen.maxX)
            let moved = OverlayController.draggedFrame(frame, in: screen, pointerY: frame.midY + 20 + 30, pointerOffsetY: 20)
            XCTAssertEqual(moved.minY, frame.minY + 30)
            // Persisting the expanded position must not move it on the next pointer tick.
            if frame.height > 70 {
                let fraction = (moved.midY - screen.minY - 35) / (screen.height - 70)
                XCTAssertEqual(OverlayController.frame(in: screen, verticalFraction: fraction), moved)
            }
        }
    }
    @Test @MainActor func testOverscrollReversesImmediatelyAtBothEnds() {
        let metrics = LyricsScrollMetrics(viewportHeight: 400, contentHeight: 1000, cueCenter: 500)
        var offset = OverlayController.clampedManualScrollOffset(100_000, metrics: metrics)
        XCTAssertEqual(offset, 300)
        offset = OverlayController.clampedManualScrollOffset(offset - 10, metrics: metrics)
        XCTAssertEqual(OverlayController.lyricsOffset(viewportHeight: 400, contentHeight: 1000, cueCenter: 500, manualOffset: offset), -10)
        offset = OverlayController.clampedManualScrollOffset(-100_000, metrics: metrics)
        XCTAssertEqual(offset, -300)
        offset = OverlayController.clampedManualScrollOffset(offset + 10, metrics: metrics)
        XCTAssertEqual(OverlayController.lyricsOffset(viewportHeight: 400, contentHeight: 1000, cueCenter: 500, manualOffset: offset), -590)
        let lastCue = LyricsScrollMetrics(viewportHeight: 400, contentHeight: 1000, cueCenter: 980)
        XCTAssertEqual(OverlayController.clampedManualScrollOffset(-1000, metrics: lastCue), 0)
        XCTAssertEqual(OverlayController.lyricsOffset(viewportHeight: 400, contentHeight: 1000, cueCenter: 980, manualOffset: 10), -590)
        XCTAssertEqual(OverlayController.clampedManualScrollOffset(1000, metrics: LyricsScrollMetrics(viewportHeight: 400, contentHeight: 100, cueCenter: 50)), 0)
    }
    @Test @MainActor func testRequestEncodingAndContactValidation() throws {
        let track = TrackMetadata(source: "test", title: "하늘 & 빛", artist: "A+B", album: "앨범", duration: 123)
        let request = try LyricsRepository.request(for: track, contact: "https://example.org/project")
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(query.first(where: { $0.name == "track_name" })?.value, "하늘 & 빛")
        XCTAssertEqual(query.first(where: { $0.name == "artist_name" })?.value, "A+B")
        XCTAssertTrue(request.value(forHTTPHeaderField: "User-Agent")!.contains("LiveLyrics/1.0"))
        let defaultRequest = try LyricsRepository.request(for: track, contact: AppModel().contact)
        XCTAssertEqual(defaultRequest.value(forHTTPHeaderField: "User-Agent"),
                       "LiveLyrics/1.0 (https://github.com/swimim/LiveLyrics)")
        XCTAssertFalse(LyricsRepository.validContact(""))
        XCTAssertTrue(LyricsRepository.validContact("author" + "@example.org"))
        XCTAssertFalse(LyricsRepository.validContact("x\r\nHeader: y"))
        XCTAssertThrowsError(try LyricsRepository.request(for: track, contact: ""))
    }
    @Test func testReleaseVersionComparison() {
        XCTAssertTrue(ReleaseUpdateChecker.isNewer("v1.2.0", than: "1.1.9"))
        XCTAssertTrue(ReleaseUpdateChecker.isNewer("1.0.1", than: "v1.0"))
        XCTAssertFalse(ReleaseUpdateChecker.isNewer("v1.0.0", than: "1.0"))
        XCTAssertFalse(ReleaseUpdateChecker.isNewer("preview", than: "1.0"))
    }
    @Test func testRetryAfterSecondsAndHTTPDate() {
        XCTAssertEqual(LyricsRepository.retryDelay("12"), 12)
        XCTAssertEqual(LyricsRepository.retryDelay("Thu, 01 Jan 1970 00:01:00 GMT", now: Date(timeIntervalSince1970: 50)), 10)
        XCTAssertNil(LyricsRepository.retryDelay("invalid"))
    }
}
