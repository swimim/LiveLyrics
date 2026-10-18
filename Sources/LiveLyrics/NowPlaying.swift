import Foundation
import AppKit

@MainActor protocol NowPlayingProvider: AnyObject {
    var onSnapshot: ((PlaybackSnapshot) -> Void)? { get set }
    var onStatus: ((String) -> Void)? { get set }
    func start()
    func stop()
}

struct MediaRemotePayload: Decodable {
    var bundleIdentifier: String?
    var title: String?
    var artist: String?
    var album: String?
    var uniqueIdentifier: String?
    var durationMicros: Double?
    var elapsedTimeMicros: Double?
    var timestampEpochMicros: Double?
    var playbackRate: Double?
    var playing: Bool?
    func snapshot(epoch: Double = Date().timeIntervalSince1970, uptime: Double = ProcessInfo.processInfo.systemUptime) -> PlaybackSnapshot {
        let hasSession = bundleIdentifier != nil || title != nil
        let track = hasSession ? TrackMetadata(source: bundleIdentifier ?? "MediaRemote", sourceID: uniqueIdentifier, title: title ?? "", artist: artist ?? "", album: album ?? "", duration: durationMicros.map { $0 / 1_000_000 }) : nil
        let state: PlaybackState = playing.map { $0 ? .playing : .paused } ?? .unknown
        let rate = playbackRate.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? 1
        var elapsed = elapsedTimeMicros.flatMap { $0.isFinite ? $0 / 1_000_000 : nil }
        let positionReference = elapsed.flatMap { position in
            timestampEpochMicros.flatMap { timestamp in
                timestamp.isFinite ? PlaybackPositionReference(elapsed: position, timestamp: timestamp / 1_000_000) : nil
            }
        }
        // Convert the raw Unix anchor exactly once, then use the monotonic clock.
        if state == .playing, let stamp = timestampEpochMicros, stamp.isFinite, let p = elapsed {
            elapsed = p + max(0, epoch - stamp / 1_000_000) * rate
        }
        return PlaybackSnapshot(track: track, elapsed: elapsed, anchor: uptime, rate: rate, state: state,
                                positionReference: positionReference)
    }
}

@MainActor final class MediaRemoteProvider: NowPlayingProvider {
    var onSnapshot: ((PlaybackSnapshot) -> Void)?
    var onStatus: ((String) -> Void)?
    private var process: Process?
    private var pipe: Pipe?
    private var buffer = Data()
    private var generation = 0
    private var retries = 0
    private var retryTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var running = false
    private var received = false
    private var positionTimer: Timer?
    private var positionProcess: Process?
    private var positionTimeout: Task<Void, Never>?
    private var latestSnapshot: PlaybackSnapshot?
    private var snapshotRevision = 0
    static var resourceDirectory: URL {
        if let path = ProcessInfo.processInfo.environment["LIVELYRICS_RESOURCES"] { return URL(fileURLWithPath: path) }
        return Bundle.main.resourceURL ?? URL(fileURLWithPath: ".")
    }
    func start() {
        guard !running else { return }
        running = true; retries = 0; launch()
    }
    private func launch() {
        guard running else { return }
        generation += 1; let token = generation
        buffer.removeAll(); received = false
        let root = Self.resourceDirectory
        let script = root.appendingPathComponent("mediaremote-adapter.pl")
        let framework = root.appendingPathComponent("MediaRemoteAdapter.framework")
        guard FileManager.default.fileExists(atPath: script.path), FileManager.default.fileExists(atPath: framework.path) else {
            onStatus?("어댑터가 없어요. scripts/build-app.sh로 앱을 빌드해 주세요"); return
        }
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [script.path, framework.path, "stream", "--no-diff", "--micros", "--no-artwork", "--allow-missing-title", "--debounce=25"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task { @MainActor [weak self] in self?.consume(data, token: token) }
        }
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor [weak self] in self?.terminated(token: token) }
        }
        self.process = process; self.pipe = pipe
        do {
            try process.run()
            onStatus?("MediaRemote 연결 중")
            timeoutTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(8))
                guard !Task.isCancelled, let self, self.generation == token, !self.received else { return }
                self.onStatus?("현재 곡 정보를 읽을 수 없어요. 재연결하거나 Spotify 공급자를 선택해 주세요")
            }
        } catch { onStatus?("MediaRemote 실행 실패"); cleanup() }
    }
    private func consume(_ data: Data, token: Int) {
        guard generation == token, running, !data.isEmpty else { return }
        buffer.append(data)
        guard buffer.count <= 1_048_576 else { onStatus?("어댑터 응답이 너무 커요"); stop(); return }
        while let newline = buffer.firstIndex(of: 10) {
            let line = buffer.prefix(upTo: newline); buffer.removeSubrange(...newline)
            struct Event: Decodable { let type: String; let diff: Bool; let payload: MediaRemotePayload }
            guard let event = try? JSONDecoder().decode(Event.self, from: line), event.type == "data", !event.diff else {
                onStatus?("재생 정보 형식을 읽을 수 없어요"); continue
            }
            received = true; timeoutTask?.cancel()
            let snapshot = event.payload.snapshot()
            onStatus?(snapshot.track == nil ? "MediaRemote 응답 수신 · 활성 세션 없음 또는 정보 접근 불가" : "MediaRemote 연결됨")
            snapshotRevision += 1
            latestSnapshot = snapshot
            updatePositionPolling()
            onSnapshot?(snapshot)
        }
    }
    private func updatePositionPolling() {
        guard latestSnapshot?.state == .playing else {
            positionTimer?.invalidate(); positionTimer = nil
            cancelPositionQuery()
            return
        }
        guard positionTimer == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.pollPosition() }
        }
        timer.tolerance = 0.02
        RunLoop.main.add(timer, forMode: .common)
        positionTimer = timer
        pollPosition() // Refresh immediately on resume, then every second.
    }
    // A periodic result must never restore a previous song or a paused session.
    static func positionUpdate(_ data: Data, current: PlaybackSnapshot?) -> PlaybackSnapshot? {
        guard data.count <= 1_048_576, current?.state == .playing,
              let track = current?.track,
              let payload = try? JSONDecoder().decode(MediaRemotePayload.self, from: data) else { return nil }
        let snapshot = payload.snapshot()
        guard snapshot.state == .playing, snapshot.elapsed != nil,
              snapshot.track?.isSameRecording(as: track) == true else { return nil }
        return snapshot
    }
    private func pollPosition() {
        guard running, latestSnapshot?.state == .playing, positionProcess == nil else { return }
        let token = generation, revision = snapshotRevision
        let query = Process(), output = Pipe()
        let root = Self.resourceDirectory
        query.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        query.arguments = [root.appendingPathComponent("mediaremote-adapter.pl").path,
                           root.appendingPathComponent("MediaRemoteAdapter.framework").path,
                           "get", "--micros", "--no-artwork", "--allow-missing-title"]
        query.standardOutput = output
        query.standardError = FileHandle.nullDevice
        query.terminationHandler = { [weak self] process in
            let data = output.fileHandleForReading.readDataToEndOfFile()
            Task { @MainActor [weak self] in
                guard let self, self.positionProcess === process else { return }
                self.positionProcess = nil
                self.positionTimeout?.cancel(); self.positionTimeout = nil
                guard self.running, self.generation == token,
                      self.snapshotRevision == revision, process.terminationStatus == 0,
                      let snapshot = Self.positionUpdate(data, current: self.latestSnapshot) else { return }
                self.latestSnapshot = snapshot
                self.onSnapshot?(snapshot)
            }
        }
        positionProcess = query
        do {
            try query.run()
            positionTimeout = Task { [weak self] in
                try? await Task.sleep(for: .seconds(2.5))
                guard !Task.isCancelled, let self, self.positionProcess === query else { return }
                self.cancelPositionQuery()
            }
        } catch { positionProcess = nil }
    }
    private func cancelPositionQuery() {
        positionTimeout?.cancel(); positionTimeout = nil
        if let query = positionProcess {
            query.terminationHandler = nil
            if query.isRunning {
                query.terminate()
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
                    if query.isRunning { kill(query.processIdentifier, SIGKILL) }
                }
            }
        }
        positionProcess = nil
    }
    private func terminated(token: Int) {
        guard generation == token, running else { return }
        cleanup()
        onSnapshot?(PlaybackSnapshot(track: nil, elapsed: nil, state: .unknown))
        onStatus?("재생 정보 연결이 끊겼어요")
        guard retries < 2 else { return }
        retries += 1
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.launch()
        }
    }
    private func cleanup() {
        positionTimer?.invalidate(); positionTimer = nil
        cancelPositionQuery(); latestSnapshot = nil
        timeoutTask?.cancel(); pipe?.fileHandleForReading.readabilityHandler = nil
        if let process {
            process.terminationHandler = nil
            if process.isRunning {
                process.terminate()
                // Kill only this owned process if the adapter ignores graceful termination.
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                }
            }
        }
        pipe = nil; process = nil
    }
    func stop() { running = false; generation += 1; retryTask?.cancel(); cleanup(); buffer.removeAll() }
}

@MainActor final class MockNowPlayingProvider: NowPlayingProvider {
    var onSnapshot: ((PlaybackSnapshot) -> Void)?
    var onStatus: ((String) -> Void)?
    private var clock = PlaybackClock()
    private var timer: Timer?
    static let track = TrackMetadata(source: "demo", title: "작은 빛의 궤도", artist: "LiveLyrics · 오프라인 데모", album: "직접 작성한 합성 가사", duration: 48)
    static let lrc = """
    [00:01.00]고요한 화면 위로
    [00:04.00]작은 빛이 천천히 번져
    [00:07.50]지금 이 순간의 속도로
    [00:11.00]우리의 문장이 흘러가
    [00:14.50]잠시 멈춰도 괜찮아
    [00:18.00]다시 같은 자리에서
    [00:21.50]창밖의 빛을 따라 길게 이어지는 이 문장도 화면의 한가운데에 머물러
    [00:27.00]함께 부르는 첫 번째 목소리
    [00:27.00]나란히 놓인 두 번째 목소리
    [00:32.00]
    [00:35.00]빈 여백 뒤에 찾아오는
    [00:39.00]새로운 한 줄의 이야기
    [00:43.00]다시, 작은 빛의 궤도로
    """
    func start() {
        stop(); seek(0, playing: true); onStatus?("오프라인 데모 · 실제 음악 재생이 아닙니다")
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let position = self.clock.position() else { return }
                if position >= 48 { self.seek(0, playing: true) }
            }
        }
    }
    func toggle() { seek(clock.position() ?? 0, playing: clock.snapshot?.state != .playing) }
    func seek(_ position: Double, playing: Bool? = nil) {
        let snapshot = PlaybackSnapshot(track: Self.track, elapsed: min(48, max(0, position)), state: (playing ?? (clock.snapshot?.state == .playing)) ? .playing : .paused)
        clock.snapshot = snapshot; onSnapshot?(snapshot)
    }
    func stop() { timer?.invalidate(); timer = nil }
}
