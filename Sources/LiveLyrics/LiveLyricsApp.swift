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
    private let releaseChecker = ReleaseUpdateChecker()
    private var overlay: OverlayController?
    private var statusItem: NSStatusItem?
    private weak var trackItem: NSMenuItem?
    private var playbackObservation: AnyCancellable?
    private var singingTimer: Timer?
    private var singingFrame = 0
    private lazy var restingIcon = Self.menuBarIcon()
    private lazy var singingIcons = (0..<4).map { Self.menuBarIcon(frame: $0) }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        if CommandLine.arguments.contains("--demo") { model.source = .demo }
        overlay = OverlayController(model: model, releaseChecker: releaseChecker)
        overlay?.setVisible(true)
        createMenuBar()
        model.start()
        releaseChecker.start()
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

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "LiveLyrics 종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp; menu.addItem(quit)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem?.button?.image = restingIcon
        statusItem?.button?.toolTip = "LiveLyrics"
        statusItem?.menu = menu
        updateMenuState()
        playbackObservation = model.$playbackState.combineLatest(model.$track)
            .map { state, track in state == .playing && track != nil }
            .removeDuplicates()
            .sink { [weak self] playing in self?.updateSingingAnimation(playing: playing) }
    }

    private func updateSingingAnimation(playing: Bool) {
        singingTimer?.invalidate(); singingTimer = nil
        singingFrame = 0
        guard playing else {
            statusItem?.button?.image = restingIcon
            return
        }
        statusItem?.button?.image = singingIcons[0]
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.singingFrame = (self.singingFrame + 1) % self.singingIcons.count
                self.statusItem?.button?.image = self.singingIcons[self.singingFrame]
            }
        }
        timer.tolerance = 0.02
        // Keep singing while the menu itself is open, without touching the lyric clock.
        RunLoop.main.add(timer, forMode: .common)
        singingTimer = timer
    }

    private static func menuBarIcon(frame: Int? = nil) -> NSImage {
        // A tiny singing stone: stepped outline, bright eyes and a microphone.
        // Transparent details remain legible when macOS tints the template.
        let pixels = [
            "       ####       ",
            "      ######      ",
            "     ########     ",
            "    ##########    ",
            "   ############   ",
            "  ##############  ",
            "  ##############  ",
            " #####  ###  #### ",
            " #####  ###  #### ",
            "##################",
            "###   ###  #######",
            "## # # ###########",
            "##  #  ###########",
            " ## # ########### ",
            "  ##  ##########  ",
            "  ## ##########   ",
            " ##  ###  ###     ",
            "     ###  ###     "
        ]
        var animatedPixels = pixels.map(Array.init)
        if let frame {
            // The mouth opens and closes next to the microphone; eyes blink on beat.
            for row in 10...12 {
                for column in 8...10 { animatedPixels[row][column] = "#" }
            }
            let mouthHeight = [1, 2, 3, 2][frame]
            for row in 10..<(10 + mouthHeight) {
                animatedPixels[row][9] = " "
                if frame != 0 { animatedPixels[row][10] = " " }
            }
            if frame == 2 {
                for column in [6, 7, 11, 12] { animatedPixels[7][column] = "#" }
            }
            // A small eighth note rises beside the head over the four-frame loop.
            let noteRow = frame % 2
            for (column, row) in [(16, noteRow), (17, noteRow), (16, noteRow + 1),
                                  (16, noteRow + 2), (15, noteRow + 3), (16, noteRow + 3)] {
                animatedPixels[row][column] = "#"
            }
        }
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.setFill()
            for (row, line) in animatedPixels.enumerated() {
                for (column, pixel) in line.enumerated() where pixel == "#" {
                    NSBezierPath(rect: NSRect(x: column, y: 17 - row, width: 1, height: 1)).fill()
                }
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "LiveLyrics · 노래하는 돌 캐릭터"
        return image
    }

    func menuWillOpen(_ menu: NSMenu) { updateMenuState() }
    private func updateMenuState() {
        if let track = model.track, !track.title.trimmed.isEmpty {
            trackItem?.title = track.artist.trimmed.isEmpty ? track.title : "\(track.title) · \(track.artist)"
        } else {
            trackItem?.title = model.source == .demo ? "오프라인 데모 준비 중" : "재생 중인 곡이 없어요"
        }
        statusItem?.button?.toolTip = model.track?.title ?? "LiveLyrics"
    }

    func applicationWillTerminate(_ notification: Notification) {
        singingTimer?.invalidate(); singingTimer = nil
        playbackObservation?.cancel(); playbackObservation = nil
        model.stop(); overlay?.close()
    }
}
