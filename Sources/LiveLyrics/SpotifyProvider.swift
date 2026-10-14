import AppKit
import Foundation

/// Spotify-only fallback. It never starts Spotify or sends playback commands.
@MainActor final class SpotifyProvider: NowPlayingProvider {
    var onSnapshot: ((PlaybackSnapshot) -> Void)?
    var onStatus: ((String) -> Void)?
    private var timer: Timer?
    private var task: Process?
    private var timeout: Task<Void, Never>?
    private var generation = 0
    private var denied = false
    private var running = false
    private static let script = #"""
    const app = Application('com.spotify.client');
    if (!app.running()) {
        JSON.stringify({running:false});
    } else {
        const state = app.playerState();
        if (state === 'stopped') {
            JSON.stringify({running:true, state:state});
        } else {
            const t = app.currentTrack();
            JSON.stringify({running:true, state:state, title:t.name(), artist:t.artist(), album:t.album(), id:t.id(), position:app.playerPosition(), duration:t.duration()});
        }
    }
    """#
    // Spotify's installed dictionary labels duration as seconds, but versions have
    // returned milliseconds. Omit this optional field until verified on this host.
    func start() {
        stop(); running = true; denied = false
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.poll() }
        }
    }
    private func poll() {
        guard running, !denied, task == nil else { return }
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: "com.spotify.client").isEmpty else {
            onStatus?("Spotify를 실행하고 음악을 재생해 주세요")
            onSnapshot?(PlaybackSnapshot(track: nil, elapsed: nil, state: .stopped)); return
        }
        generation += 1; let token = generation
        let process = Process(), output = Pipe(), errors = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-l", "JavaScript", "-e", Self.script]
        process.standardOutput = output; process.standardError = errors
        process.terminationHandler = { [weak self] process in
            let data = output.fileHandleForReading.readDataToEndOfFile()
            let error = errors.fileHandleForReading.readDataToEndOfFile()
            Task { @MainActor [weak self] in
                self?.finish(data: data, error: error, code: process.terminationStatus, token: token)
            }
        }
        task = process
        do {
            try process.run()
            timeout = Task { [weak self] in
                // Allow enough time to answer the system's initial Automation prompt.
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled, let self, self.generation == token, process.isRunning else { return }
                self.onStatus?("Spotify 응답 시간 초과 · 재연결을 눌러 주세요")
                self.stop()
            }
        } catch { task = nil; onStatus?("Spotify 정보 읽기를 시작할 수 없어요") }
    }
    private func finish(data: Data, error: Data, code: Int32, token: Int) {
        guard token == generation, running else { return }
        task = nil; timeout?.cancel()
        let errorText = String(data: error, encoding: .utf8) ?? ""
        if code != 0 {
            onSnapshot?(PlaybackSnapshot(track: nil, elapsed: nil, state: .unknown))
            // Stop all polling errors to avoid repeated authorization requests.
            denied = true; timer?.invalidate(); timer = nil
            onStatus?(errorText.contains("1743") ? "Spotify 자동화 권한이 거부됐어요. 시스템 설정 → 개인정보 보호 및 보안 → 자동화를 확인해 주세요" : "Spotify 정보를 읽을 수 없어요. 재연결을 눌러 주세요")
            return
        }
        struct Payload: Decodable { var running: Bool; var state: String?; var title: String?; var artist: String?; var album: String?; var id: String?; var position: Double?; var duration: Double? }
        guard let value = try? JSONDecoder().decode(Payload.self, from: data), data.count < 65_536 else {
            onStatus?("Spotify 응답 형식을 읽을 수 없어요"); return
        }
        let state: PlaybackState = value.state == "playing" ? .playing : value.state == "paused" ? .paused : .stopped
        let duration = value.duration.flatMap { raw -> Double? in
            guard raw.isFinite, raw > 0 else { return nil }
            let seconds = raw > 3600 && raw <= 3_600_000 ? raw / 1000 : raw
            return seconds <= 3600 ? seconds : nil
        }
        let track = value.title.map { TrackMetadata(source: "com.spotify.client", sourceID: value.id, title: $0, artist: value.artist ?? "", album: value.album ?? "", duration: duration) }
        onStatus?("Spotify 전용 연결 · 1초 간격 조회")
        onSnapshot?(PlaybackSnapshot(track: track, elapsed: value.position, state: state))
    }
    func stop() {
        running = false; generation += 1; timer?.invalidate(); timer = nil; timeout?.cancel()
        if let process = task {
            process.terminationHandler = nil
            if process.isRunning {
                process.terminate()
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                }
            }
        }
        task = nil
    }
}
