import SwiftUI
import AppKit

private struct HeightsKey: PreferenceKey {
    static var defaultValue: [Int: CGFloat] = [:]
    static func reduce(value: inout [Int: CGFloat], nextValue: () -> [Int: CGFloat]) { value.merge(nextValue(), uniquingKeysWith: { _, new in new }) }
}

/// A shear ensures Korean fallback glyphs are slanted as well as Latin glyphs.
private struct ItalicShear: GeometryEffect {
    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(a: 1, b: 0, c: -0.16, d: 1, tx: size.height * 0.08, ty: 0))
    }
}

struct LyricsOverlayView: View {
    @ObservedObject var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var heights: [Int: CGFloat] = [:]
    private let gray = Color(red: 92 / 255, green: 96 / 255, blue: 102 / 255)
    var body: some View {
        GeometryReader { viewport in
            if let message = model.overlayMessage, model.pointerInsideLyricsArea {
                Text(message).font(.system(size: 18, weight: .medium)).foregroundStyle(gray)
                    .multilineTextAlignment(.trailing)
                    .padding(.trailing, 20)
                    .frame(width: viewport.size.width, height: viewport.size.height, alignment: .trailing)
            } else if model.hasDisplayableLyrics,
                      (model.pointerInsideLyricsArea || model.lyricsLocked) {
                let center = cueCenter(model.displayedLyricIndex ?? 0)
                VStack(spacing: 20) {
                    ForEach(model.document.cues) { cue in
                        Text(cue.text.isEmpty ? " " : cue.text)
                            .font(.system(size: 24, weight: .medium))
                            .multilineTextAlignment(.center)
                            .foregroundStyle(!model.isLyricsFinished && !model.isBeforeFirstLyric && cue.id == model.activeIndex ? Color.white : gray)
                            .animation(nil, value: model.activeIndex)
                            .lineLimit(max(2, Int((viewport.size.height - 48) / 30)))
                            .truncationMode(.middle)
                            .fixedSize(horizontal: false, vertical: true)
                            .modifier(ItalicShear())
                            .frame(maxWidth: .infinity, alignment: .center)
                            .background(GeometryReader { proxy in
                                Color.clear.preference(key: HeightsKey.self, value: [cue.id: proxy.size.height])
                            })
                    }
                }
                .padding(.leading, 20)
                .padding(.trailing, 20)
                .frame(width: viewport.size.width, height: viewport.size.height, alignment: .topTrailing)
                .offset(y: OverlayController.verticalScrollOffset(viewportHeight: viewport.size.height, cueCenter: center))
                .animation(model.animateTransition && !reduceMotion ? .easeInOut(duration: 0.24) : nil, value: model.activeIndex)
                .onPreferenceChange(HeightsKey.self) { heights = $0 }
                .onChange(of: model.track?.key) { _, _ in heights = [:] }
            }
        }
        .clipped()
        .accessibilityLabel("LiveLyrics 동기화 가사")
    }
    private func cueCenter(_ index: Int) -> CGFloat {
        let fallback: CGFloat = 30
        var center: CGFloat = 0
        for previous in 0..<index { center += (heights[previous] ?? fallback) + 20 }
        return center + (heights[index] ?? fallback) / 2
    }
}

final class LyricsPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor final class OverlayController {
    let panel: LyricsPanel
    private weak var model: AppModel?
    private var observer: NSObjectProtocol?
    private var pointerTimer: Timer?
    private var displayID: CGDirectDisplayID?
    static func frame(in screen: CGRect) -> CGRect {
        CGRect(x: screen.minX + screen.width * 3 / 4, y: screen.minY + screen.height / 4,
               width: screen.width / 4, height: screen.height / 2)
    }
    static func verticalScrollOffset(viewportHeight: CGFloat, cueCenter: CGFloat) -> CGFloat {
        min(0, viewportHeight / 2 - cueCenter)
    }
    init(model: AppModel) {
        self.model = model
        panel = LyricsPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.alphaValue = 1; panel.ignoresMouseEvents = true; panel.hidesOnDeactivate = false
        panel.level = .floating; panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        let hosting = NSHostingView(rootView: LyricsOverlayView(model: model))
        hosting.wantsLayer = true; hosting.layer?.backgroundColor = NSColor.clear.cgColor
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
        displayID = NSScreen.screens.first?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        relocate()
        pointerTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.updatePointerPosition() }
        }
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.relocate() }
        }
    }
    func relocate() {
        guard let screen = NSScreen.screens.first(where: { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == displayID }) ?? NSScreen.screens.first else { return }
        displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        panel.setFrame(Self.frame(in: screen.frame), display: true)
    }
    private func updatePointerPosition() {
        let hovering = panel.isVisible && panel.frame.contains(NSEvent.mouseLocation)
        if model?.pointerInsideLyricsArea != hovering { model?.pointerInsideLyricsArea = hovering }
    }
    func setVisible(_ visible: Bool) {
        if visible { panel.orderFrontRegardless() } else { panel.orderOut(nil); model?.pointerInsideLyricsArea = false }
    }
    func close() {
        pointerTimer?.invalidate(); pointerTimer = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }
        panel.close()
    }
}
