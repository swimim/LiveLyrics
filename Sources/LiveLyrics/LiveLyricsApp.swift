import AppKit
import Combine

@main enum LiveLyricsApp {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let model = AppModel()
    private var overlay: OverlayController?
    private var statusItem: NSStatusItem?
    private var visibility: AnyCancellable?
    private weak var lyricsItem: NSMenuItem?
    private weak var lockItem: NSMenuItem?
    private weak var statusTextItem: NSMenuItem?
    private weak var trackItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        if CommandLine.arguments.contains("--demo") { model.source = .demo }
        overlay = OverlayController(model: model)
        // Retain the Combine token for the whole menu-bar app lifetime.
        visibility = model.$overlayVisible.sink { [weak self] visible in self?.overlay?.setVisible(visible) }
        createMenuBar()
        model.start()
        if let i = CommandLine.arguments.firstIndex(of: "--smoke-test"), CommandLine.arguments.indices.contains(i + 1), let seconds = Double(CommandLine.arguments[i + 1]) {
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { NSApp.terminate(nil) }
        }
    }

    private func createMenuBar() {
        let menu = NSMenu()
        menu.delegate = self
        let track = NSMenuItem(title: "재생 중인 곡이 없어요", action: nil, keyEquivalent: "")
        track.isEnabled = false
        menu.addItem(track); trackItem = track

        let status = NSMenuItem(title: model.lyricsState.message, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status); statusTextItem = status

        menu.addItem(.separator())
        let lyrics = NSMenuItem(title: "가사 표시", action: #selector(toggleLyrics(_:)), keyEquivalent: "")
        lyrics.target = self; lyrics.state = model.overlayVisible ? .on : .off
        menu.addItem(lyrics); lyricsItem = lyrics

        let lock = NSMenuItem(title: "가사 잠금", action: #selector(toggleLyricsLock(_:)), keyEquivalent: "")
        lock.target = self; lock.state = model.lyricsLocked ? .on : .off
        menu.addItem(lock); lockItem = lock

        menu.addItem(.separator())
        let reconnect = NSMenuItem(title: "다시 연결", action: #selector(reconnect), keyEquivalent: "")
        reconnect.target = self; menu.addItem(reconnect)
        let refresh = NSMenuItem(title: "가사 새로고침", action: #selector(refreshLyrics), keyEquivalent: "")
        refresh.target = self; menu.addItem(refresh)

        let contact = NSMenuItem(title: "LRCLIB 연락처 등록/변경…", action: #selector(changeContact), keyEquivalent: "")
        contact.target = self; menu.addItem(contact)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "LiveLyrics 종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp; menu.addItem(quit)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem?.button?.image = NSImage(systemSymbolName: "text.quote", accessibilityDescription: "LiveLyrics")
        statusItem?.button?.toolTip = "LiveLyrics · 메뉴에서 가사 표시와 연결을 설정"
        statusItem?.menu = menu
        updateMenuState()
    }

    func menuWillOpen(_ menu: NSMenu) { updateMenuState() }
    private func updateMenuState() {
        lyricsItem?.state = model.overlayVisible ? .on : .off
        lockItem?.state = model.lyricsLocked ? .on : .off
        statusTextItem?.title = model.lyricsState == .idle ? model.providerStatus : model.lyricsState.message
        if let track = model.track, !track.title.trimmed.isEmpty {
            trackItem?.title = track.artist.trimmed.isEmpty ? track.title : "\(track.title) · \(track.artist)"
        } else {
            trackItem?.title = model.source == .demo ? "오프라인 데모 준비 중" : "재생 중인 곡이 없어요"
        }
        statusItem?.button?.toolTip = model.track?.title ?? "LiveLyrics · 가사를 \(model.overlayVisible ? "표시" : "숨김")"
    }

    @objc private func toggleLyrics(_ sender: NSMenuItem) { model.overlayVisible.toggle(); updateMenuState() }
    @objc private func toggleLyricsLock(_ sender: NSMenuItem) { model.lyricsLocked.toggle(); updateMenuState() }
    @objc private func reconnect() { model.connect(); updateMenuState() }
    @objc private func refreshLyrics() { model.refresh(); updateMenuState() }

    @objc private func changeContact() {
        let alert = NSAlert()
        alert.messageText = "LRCLIB 앱 식별 정보"
        alert.informativeText = "곡을 조회할 때 곡명·아티스트·앨범·길이와 아래 연락처가 LRCLIB에 전송됩니다."
        alert.addButton(withTitle: "저장")
        alert.addButton(withTitle: "취소")
        let field = NSTextField(string: model.contact)
        field.placeholderString = "프로젝트 URL 또는 이메일"
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard model.saveContact(field.stringValue) else {
            let invalid = NSAlert()
            invalid.messageText = "올바른 URL 또는 이메일을 입력해 주세요"
            invalid.runModal()
            return
        }
        updateMenuState()
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.stop(); overlay?.close()
    }
}
