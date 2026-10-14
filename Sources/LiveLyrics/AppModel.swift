import SwiftUI
import AppKit

@MainActor final class AppModel: ObservableObject {
    enum Source: String, CaseIterable, Identifiable { case mediaRemote = "macOS 현재 재생", spotify = "Spotify 전용", demo = "오프라인 데모"; var id: String { rawValue } }
    @Published var source: Source = .mediaRemote
    @Published var track: TrackMetadata?
    @Published var document = LyricsDocument()
    @Published var lyricsState: LyricsState = .idle
    @Published var providerStatus = "연결 준비 중"
    @Published var playbackState: PlaybackState = .unknown
    @Published var activeIndex: Int?
    @Published var positionKnown = false
    @Published var animateTransition = false
    @Published var overlayVisible = true { didSet { updateTimer(); synchronize(animate: false) } }
    @Published var pointerInsideLyricsArea = false
    @Published var lyricsLocked = UserDefaults.standard.bool(forKey: "lyricsLocked") {
        didSet { UserDefaults.standard.set(lyricsLocked, forKey: "lyricsLocked") }
    }
    @Published var contact: String = UserDefaults.standard.string(forKey: "lrclibContact") ?? ""
    private(set) var clock = PlaybackClock()
    private var provider: NowPlayingProvider?
    private let repository: LyricsRepository
    private var request: Task<Void, Never>?
    private var generation = RequestGeneration()
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var sleeping = false
    var demo: MockNowPlayingProvider? { provider as? MockNowPlayingProvider }
    var overlayMessage: String? {
        guard track != nil else { return nil }
        if !track!.isQueryable { return "곡 정보를 확인하고 있어요" }
        if lyricsState == .synced && !positionKnown { return "재생 위치를 확인할 수 없어요" }
        return lyricsState == .synced ? nil : lyricsState.message
    }
    var isLyricsFinished: Bool {
        guard lyricsState == .synced, let activeIndex,
              let lastLyricIndex = document.cues.lastIndex(where: { !$0.text.trimmed.isEmpty }) else { return false }
        return activeIndex > lastLyricIndex
    }
    var isBeforeFirstLyric: Bool {
        guard let activeIndex,
              let firstLyricIndex = document.cues.firstIndex(where: { !$0.text.trimmed.isEmpty }) else { return true }
        return activeIndex < firstLyricIndex
    }
    var displayedLyricIndex: Int? {
        if isBeforeFirstLyric { return document.cues.firstIndex(where: { !$0.text.trimmed.isEmpty }) }
        guard isLyricsFinished else { return activeIndex }
        return document.cues.lastIndex(where: { !$0.text.trimmed.isEmpty })
    }
    var hasDisplayableLyrics: Bool {
        guard lyricsState == .synced, positionKnown else { return false }
        if isLyricsFinished || isBeforeFirstLyric { return !document.cues.isEmpty }
        guard let activeIndex, document.cues.indices.contains(activeIndex) else { return false }
        return !document.cues[activeIndex].text.trimmed.isEmpty
    }
    init(repository: LyricsRepository = LyricsRepository()) { self.repository = repository }
    func start() {
        guard observers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.suspend() }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.sleeping = false; self?.connect() }
        })
        connect()
    }
    private func suspend() {
        sleeping = true; provider?.stop(); timer?.invalidate(); timer = nil
        if var s = clock.snapshot { s.elapsed = clock.position(); s.anchor = ProcessInfo.processInfo.systemUptime; s.state = .paused; clock.snapshot = s }
        providerStatus = "잠자기 · 복귀 후 다시 연결합니다"
    }
    func connect() {
        provider?.stop(); request?.cancel(); _ = generation.begin(nil)
        track = nil; document = LyricsDocument(); activeIndex = nil; clock.snapshot = nil
        lyricsState = .idle; positionKnown = false; playbackState = .unknown; animateTransition = false
        switch source {
        case .demo: provider = MockNowPlayingProvider()
        case .mediaRemote: provider = MediaRemoteProvider()
        case .spotify: provider = SpotifyProvider()
        }
        provider?.onSnapshot = { [weak self] in self?.receive($0) }
        provider?.onStatus = { [weak self] in self?.providerStatus = $0 }
        provider?.start(); updateTimer()
    }
    func receive(_ incoming: PlaybackSnapshot) {
        var snapshot = incoming
        let predicted = clock.position()
        if snapshot.track == nil, let current = track {
            switch snapshot.state {
            case .unknown:
                // Spotify can briefly lose its metadata while still playing.
                // Keep the last clock running until a new track or its end arrives.
                providerStatus = "곡 정보를 다시 확인하는 중 · 현재 가사를 유지합니다"
                return
            case .stopped:
                let position = snapshot.elapsed ?? predicted
                let reachedEnd = current.duration.map { duration in
                    duration.isFinite && duration > 0 && (position ?? 0) >= duration - 1
                } ?? false
                if reachedEnd {
                    clearCurrentTrack()
                    return
                }
                // A stopped event without metadata may be a transient Spotify
                // handoff. Freeze the existing song at the last known position.
                snapshot = PlaybackSnapshot(track: current, elapsed: position, rate: 0, state: .paused)
            case .playing, .paused:
                // Retain lyrics and use the previous clock if position is absent.
                snapshot.track = current
                if snapshot.elapsed == nil { snapshot.elapsed = predicted }
            }
        }
        let changed = snapshot.track?.key != track?.key
        let seeking = predicted.flatMap { p in snapshot.elapsed.map { abs(p - $0) > 0.6 } } ?? true
        clock.snapshot = snapshot; positionKnown = clock.position() != nil; playbackState = snapshot.state
        track = snapshot.track
        if changed {
            request?.cancel(); _ = generation.begin(track?.key)
            document = LyricsDocument(); activeIndex = nil; animateTransition = false
            guard let track else { lyricsState = .idle; updateTimer(); return }
            if source == .demo {
                document = (try? LRCParser.parse(MockNowPlayingProvider.lrc)) ?? LyricsDocument()
                lyricsState = .synced
            } else if track.isQueryable { load(track) }
            else { lyricsState = .failed("곡 정보를 확인하고 있어요") }
        }
        synchronize(animate: !changed && !seeking); updateTimer()
    }
    @discardableResult func saveContact(_ value: String) -> Bool {
        guard LyricsRepository.validContact(value) else { return false }
        contact = value.trimmed
        UserDefaults.standard.set(contact, forKey: "lrclibContact")
        refresh()
        return true
    }
    func refresh() { if let track, source != .demo { load(track, refresh: true) } }
    private func load(_ track: TrackMetadata, refresh: Bool = false) {
        // Pick up a contact saved outside this process as well, then use the
        // current value for request validation and its User-Agent.
        if let savedContact = UserDefaults.standard.string(forKey: "lrclibContact"), savedContact != contact {
            contact = savedContact
        }
        request?.cancel()
        let token = generation.begin(track.key), contact = self.contact
        lyricsState = .loading
        request = Task { [weak self, repository] in
            do {
                try await Task.sleep(for: .milliseconds(300))
                let result = try await repository.fetch(track, contact: contact, refresh: refresh)
                guard let self, !Task.isCancelled, self.generation.accepts(token, key: track.key) else { return }
                self.document = result
                self.lyricsState = result.instrumental ? .instrumental : !result.cues.isEmpty ? .synced : .plain
                self.synchronize(animate: false); self.updateTimer()
            } catch is CancellationError { }
            catch {
                guard let self, !Task.isCancelled, self.generation.accepts(token, key: track.key) else { return }
                // A failed refresh preserves already downloaded lyrics.
                if !self.document.cues.isEmpty || self.document.plain != nil {
                    self.lyricsState = self.document.cues.isEmpty ? .plain : .synced
                    self.providerStatus = "새로고침 실패 · 저장된 가사를 유지해요"
                } else if let error = error as? LyricsError {
                    switch error {
                    case .notFound: self.lyricsState = .notFound
                    case .mismatch: self.lyricsState = .needsSelection
                    default: self.lyricsState = .failed(error.localizedDescription)
                    }
                } else { self.lyricsState = .failed("가사를 불러오지 못했어요. 인터넷 연결을 확인해 주세요") }
                self.updateTimer()
            }
        }
    }
    func synchronize(animate: Bool) {
        if let duration = track?.duration, duration.isFinite, duration > 0,
           let position = clock.position(), position >= duration {
            clearCurrentTrack()
            return
        }
        let next = clock.position().map { LyricsSynchronizer.index(in: document, position: $0) } ?? nil
        if next != activeIndex {
            animateTransition = animate && activeIndex != nil && next == activeIndex.map { $0 + 1 }
            activeIndex = next
        } else if !animate { animateTransition = false }
    }
    private func updateTimer() {
        let needed = !sleeping && overlayVisible && playbackState == .playing && positionKnown &&
            (lyricsState == .synced || track?.duration != nil)
        if !needed { timer?.invalidate(); timer = nil }
        else if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in self?.synchronize(animate: true) }
            }
        }
    }
    private func clearCurrentTrack() {
        request?.cancel(); _ = generation.begin(nil)
        track = nil; document = LyricsDocument(); activeIndex = nil
        lyricsState = .idle; playbackState = .stopped; positionKnown = false
        clock.snapshot = nil; animateTransition = false
        providerStatus = "재생이 끝났어요"
        updateTimer()
    }
    func stop() {
        request?.cancel(); provider?.stop(); timer?.invalidate(); timer = nil
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }; observers.removeAll()
    }
}
