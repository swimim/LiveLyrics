import SwiftUI
import AppKit

private struct HeightsKey: PreferenceKey {
    static var defaultValue: [Int: CGFloat] = [:]
    static func reduce(value: inout [Int: CGFloat], nextValue: () -> [Int: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

/// A shear ensures Korean fallback glyphs are slanted as well as Latin glyphs.
private struct ItalicShear: GeometryEffect {
    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(a: 1, b: 0, c: -0.16, d: 1, tx: size.height * 0.08, ty: 0))
    }
}

private struct PressFeedbackButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.88 : 1)
            .opacity(configuration.isPressed ? 0.72 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct LyricsOverlayView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var controller: OverlayController
    @ObservedObject var releaseChecker: ReleaseUpdateChecker
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var heights: [Int: CGFloat] = [:]
    @State private var scrollAnchorIndex: Int?
    @State private var statusCollapseTask: Task<Void, Never>?
    @Namespace private var mascotMorph
    private let gray = Color(red: 92 / 255, green: 96 / 255, blue: 102 / 255)
    private var shouldShowOverlayContent: Bool {
        model.lyricsState == .loading || model.pointerInsideLyricsArea || model.lyricsLocked || controller.automaticallyRevealed
    }

    private var presentation: some View {
        Group {
            if controller.isExpanded {
                ZStack {
                    VStack(spacing: 0) {
                        HStack(spacing: 7) {
                            if model.pointerInsideLyricsArea {
                                Button { model.reconnectAndRefresh() } label: {
                                    Image(systemName: "arrow.clockwise")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(.white)
                                        .frame(width: 24, height: 24)
                                        .background(.white.opacity(0.12), in: Circle())
                                        .overlay(Circle().strokeBorder(.white.opacity(0.2), lineWidth: 1))
                                }
                                .buttonStyle(.plain)
                                .help("다시 연결하고 가사 새로고침")
                                .accessibilityLabel("다시 연결하고 가사 새로고침")
                                if let release = releaseChecker.availableRelease {
                                    Button { NSWorkspace.shared.open(release.downloadURL) } label: {
                                        Image(systemName: "arrow.down.circle.fill")
                                            .font(.system(size: 14, weight: .semibold))
                                            .foregroundStyle(.white)
                                            .frame(width: 24, height: 24)
                                    }
                                    .buttonStyle(.plain)
                                    .help("LiveLyrics \(release.version) 다운로드")
                                    .accessibilityLabel("LiveLyrics \(release.version) 다운로드")
                                }
                                Spacer(minLength: 8)
                                Toggle("Auto", isOn: $model.autoShowLyrics)
                                    .toggleStyle(.checkbox)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(.white)
                                Toggle("Lock", isOn: $model.lyricsLocked)
                                    .toggleStyle(.checkbox)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(.white)
                                Button(action: controller.collapse) {
                                    Circle()
                                        .fill(Color(red: 1, green: 0.36, blue: 0.34))
                                        .frame(width: 16, height: 16)
                                }
                                .buttonStyle(PressFeedbackButtonStyle())
                                .frame(width: 30, height: 30)
                                .help("아이콘으로 접기")
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .frame(height: OverlayController.menuHeight)
                        .padding(.horizontal, 8)
                        .contentShape(Rectangle())


                        lyricsView
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .clipped()
                        Color.clear
                            .frame(height: OverlayController.menuHeight)
                            .allowsHitTesting(false)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .transition(.identity)
            } else {
                ZStack {
                    Image(nsImage: appIcon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 50, height: 50)
                        .matchedGeometryEffect(id: "pixel-pal", in: mascotMorph)
                        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                        .padding(10)
                }
                .frame(width: 70, height: 70)
                .opacity(0.9)
                .onHover { controller.setTileHovered($0) }
                .contentShape(UnevenRoundedRectangle(
                    cornerRadii: RectangleCornerRadii(
                        topLeading: 30,
                        bottomLeading: 30,
                        bottomTrailing: 0,
                        topTrailing: 0
                    ),
                    style: .continuous
                ))
                .onTapGesture { controller.expand() }
                .gesture(DragGesture(minimumDistance: 3)
                    .onChanged { _ in controller.dragCollapsedTile() }
                    .onEnded { _ in controller.finishCollapsedTileDrag() })
                .accessibilityElement()
                .accessibilityLabel("가사 보기")
                .accessibilityAddTraits(.isButton)
                .accessibilityAction(.default) { controller.expand() }
                .help("가사 보기")
                .transition(.identity)
            }
        }
    }

    var body: some View {
        presentation
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .background {
            overlaySurface
                .fill(.ultraThinMaterial)
                .overlay {
                    overlaySurface.strokeBorder(
                        controller.isTileHovered ? Color.gray.opacity(0.34) : Color.white.opacity(controller.isExpanded ? 0.16 : 0.22),
                        lineWidth: controller.isTileHovered ? 0.7 : 1
                    )
                }
                .animation(.easeInOut(duration: 0.16), value: controller.isTileHovered)
                .opacity(surfaceOpacity)
                .animation(controller.overlayTransitionAnimation, value: controller.isExpanded)
        }
        .accessibilityLabel("LiveLyrics 동기화 가사")
        .onAppear { scheduleStatusCollapse() }
        .onChange(of: model.lyricsState) { _, _ in scheduleStatusCollapse() }
        .onChange(of: model.hasDisplayableLyrics) { _, _ in
            controller.revealLyricsIfNeeded()
            scheduleStatusCollapse()
        }
        .onChange(of: model.activeIndex) { _, _ in updateScrollAnchor() }
        .onChange(of: model.track?.key) { _, _ in
            scrollAnchorIndex = nil
            heights = [:]
            controller.resetLyricsScroll()
            controller.revealLyricsIfNeeded()
        }
        .onChange(of: model.pointerInsideLyricsArea) { _, _ in
            scheduleStatusCollapse()
        }
        .onChange(of: controller.isExpanded) { _, _ in
            scheduleStatusCollapse()
        }
        .onDisappear {
            statusCollapseTask?.cancel(); statusCollapseTask = nil
        }
    }

    private func updateScrollAnchor() {
        // Stay mounted while the lyrics subtree is hidden in tile/hover mode.
        guard model.playbackState == .playing else { return }
        let animate = controller.isExpanded && shouldShowOverlayContent && model.animateTransition && !reduceMotion
        withAnimation(animate ? .easeInOut(duration: 0.28) : nil) {
            scrollAnchorIndex = model.displayedLyricIndex ?? 0
            controller.resetLyricsScroll()
        }
    }

    private func scheduleStatusCollapse() {
        statusCollapseTask?.cancel()
        statusCollapseTask = nil
        guard controller.isExpanded, model.lyricsState != .loading,
              !model.pointerInsideLyricsArea, !model.hasDisplayableLyrics else { return }
        statusCollapseTask = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(1.5)) }
            catch { return }
            guard !Task.isCancelled, model.lyricsState != .loading,
                  !model.hasDisplayableLyrics, controller.isExpanded, !model.pointerInsideLyricsArea else { return }
            controller.collapse(duration: 0.1, accelerating: true)
        }
    }

    private var overlaySurface: UnevenRoundedRectangle {
        let expandedRadius: CGFloat = 20
        let tileRadius: CGFloat = 30
        let isExpanded = controller.isExpanded
        return UnevenRoundedRectangle(
            cornerRadii: RectangleCornerRadii(
                topLeading: isExpanded ? expandedRadius : tileRadius,
                bottomLeading: isExpanded ? expandedRadius : tileRadius,
                bottomTrailing: isExpanded ? expandedRadius : 0,
                topTrailing: isExpanded ? expandedRadius : 0
            ),
            style: .continuous
        )
    }

    private var surfaceOpacity: Double {
        if !controller.isExpanded { return 0.9 }
        return shouldShowOverlayContent && (model.hasDisplayableLyrics || model.overlayMessage != nil)
            || controller.isMorphingToTile ? 0.9 : 0
    }

    private var lyricsView: some View {
        GeometryReader { viewport in
            if shouldShowOverlayContent, let message = model.overlayMessage {
                ZStack {
                    PixelPalAnimation()
                        .allowsHitTesting(false)
                    Text(message)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(gray)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 20)
                }
                .frame(width: viewport.size.width, height: viewport.size.height)
            } else if shouldShowOverlayContent && model.hasDisplayableLyrics {
                let center = cueCenter(scrollAnchorIndex ?? model.displayedLyricIndex ?? 0)
                VStack(spacing: 20) {
                    ForEach(model.document.cues) { cue in
                        Text(cue.text.isEmpty ? " " : cue.text)
                            .font(.system(size: 24, weight: .semibold))
                            .multilineTextAlignment(.center)
                            .foregroundStyle(!model.isLyricsFinished && !model.isBeforeFirstLyric && cue.id == model.activeIndex ? Color.white : gray)
                            .animation(model.animateTransition && !reduceMotion ? .easeInOut(duration: 0.24) : nil, value: model.activeIndex)
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
                .offset(y: OverlayController.lyricsOffset(
                    viewportHeight: viewport.size.height,
                    contentHeight: contentHeight,
                    cueCenter: center,
                    manualOffset: controller.manualScrollOffset
                ))
                .animation(model.animateTransition && !reduceMotion ? .easeInOut(duration: 0.28) : nil, value: scrollAnchorIndex)
                .onPreferenceChange(HeightsKey.self) { heights = $0 }
                .onAppear {
                    // Reconcile immediately when returning from tile/hover hiding.
                    // Do not inherit the panel morph animation or replay old cues.
                    var transaction = Transaction(animation: nil)
                    transaction.disablesAnimations = true
                    withTransaction(transaction) {
                        if model.playbackState == .playing {
                            scrollAnchorIndex = model.displayedLyricIndex ?? 0
                            controller.resetLyricsScroll()
                        } else if scrollAnchorIndex == nil {
                            scrollAnchorIndex = model.displayedLyricIndex ?? 0
                        }
                    }
                }
                .onChange(of: LyricsScrollMetrics(viewportHeight: viewport.size.height,
                                                 contentHeight: contentHeight,
                                                 cueCenter: center), initial: true) { _, metrics in
                    controller.updateScrollMetrics(metrics)
                }

            }
        }
    }

    private var appIcon: NSImage {
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let image = NSImage(contentsOf: url) { return image }
        return NSImage(systemSymbolName: "text.quote", accessibilityDescription: "LiveLyrics")
            ?? NSImage(size: NSSize(width: 180, height: 180))
    }

    private func cueCenter(_ index: Int) -> CGFloat {
        let fallback: CGFloat = 30
        var center: CGFloat = 0
        for previous in 0..<index { center += (heights[previous] ?? fallback) + 20 }
        return center + (heights[index] ?? fallback) / 2
    }

    private var contentHeight: CGFloat {
        guard !model.document.cues.isEmpty else { return 0 }
        return model.document.cues.reduce(CGFloat.zero) { $0 + (heights[$1.id] ?? 30) }
            + CGFloat(max(0, model.document.cues.count - 1)) * 20
    }
}

/// A separate pixel sprite inspired by the singing stone in the app icon.
private struct PixelPalAnimation: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let sprite = [
        "          dddd          ",
        "        ddhhhhdd        ",
        "      ddhhssssssdd      ",
        "     dhhhssssssssssd    ",
        "    dhhhssssssssssssd   ",
        "   dhhccssssssssssssd   ",
        "   dhccccssssssssssssd  ",
        "  dhcccccchssssssssssd  ",
        "  dhccccccchhhsssshssd  ",
        " dhccccccccccccccchssd ",
        " dhccsscccccccccccchssd ",
        " dhccsscccccccccccchssd ",
        "dhcccccddcccccccccccssd",
        "dhccccdwedccccddccccssd",
        "dhccccdeedcccdwedcccssd",
        "dhcpppdeedcccdeedcccssd",
        "dhcpppcccccccdeedpppssd",
        " dhcccccccddccccccpppsd ",
        " dhcccccccccccccccsssd ",
        "  dshcccccccccccchsssd  ",
        "   dshhcccccccchhsssd   ",
        "    dsshhhhhhhhssssd    ",
        "     dddddddddddddd     ",
        "      dsssd  dsssd      ",
        "       ddd    ddd       "
    ]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { timeline in
            let phase = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate * 0.7
            Canvas { context, size in
                // The orbit uses the full available width and height while
                // leaving the centered message readable and avoiding controls.
                let radius: CGFloat = 36
                let horizontal = max(0, size.width / 2 - radius)
                let vertical = max(0, size.height / 2 - radius)
                let x = size.width / 2 + horizontal * CGFloat(cos(phase))
                let y = size.height / 2 + vertical * CGFloat(sin(phase))
                var stone = context
                stone.translateBy(x: x, y: y)
                stone.rotate(by: .degrees(reduceMotion ? 0 : phase * 180))
                let pixel: CGFloat = 2
                let blinking = !reduceMotion && phase.truncatingRemainder(dividingBy: 3) < 0.12
                for (row, line) in sprite.enumerated() {
                    for (column, code) in line.enumerated() where code != " " {
                        let rect = CGRect(x: (CGFloat(column) - 12) * pixel,
                                          y: (CGFloat(row) - 12) * pixel,
                                          width: pixel, height: pixel)
                        stone.fill(Path(rect), with: .color(color(for: blinking && code == "w" ? "e" : code)))
                    }
                }
                // A little checkered microphone travels with the character.
                var microphone = stone
                microphone.translateBy(x: -14, y: 12)
                microphone.rotate(by: .degrees(25))
                microphone.fill(Path(CGRect(x: -3, y: 0, width: 6, height: 19)), with: .color(color(for: "e")))
                microphone.fill(Path(CGRect(x: -7, y: -7, width: 14, height: 14)), with: .color(color(for: "e")))
                for row in 0..<5 {
                    for column in 0..<5 {
                        let rect = CGRect(x: CGFloat(column * 2 - 5), y: CGFloat(row * 2 - 5), width: 2, height: 2)
                        microphone.fill(Path(rect), with: .color((row + column).isMultiple(of: 2)
                            ? Color(red: 0.82, green: 0.83, blue: 0.87)
                            : Color(red: 0.43, green: 0.44, blue: 0.50)))
                    }
                }
            }
        }
        .clipped()
        .accessibilityLabel("마이크를 든 작은 돌 캐릭터가 굴러다니는 애니메이션")
        .accessibilityAddTraits(.isImage)
    }

    private func color(for pixel: Character) -> Color {
        switch pixel {
        case "d": Color(red: 0.24, green: 0.13, blue: 0.10)
        case "s": Color(red: 0.63, green: 0.48, blue: 0.38)
        case "h": Color(red: 0.88, green: 0.74, blue: 0.60)
        case "c": Color(red: 0.94, green: 0.81, blue: 0.65)
        case "e": Color(red: 0.19, green: 0.12, blue: 0.11)
        case "w": .white
        case "p": Color(red: 1, green: 0.59, blue: 0.56)
        default: .clear
        }
    }
}

final class LyricsPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

struct LyricsScrollMetrics: Equatable {
    var viewportHeight: CGFloat
    var contentHeight: CGFloat
    var cueCenter: CGFloat
}

@MainActor final class OverlayController: ObservableObject {
    nonisolated static let menuHeight: CGFloat = 44
    let panel: LyricsPanel
    @Published private(set) var isExpanded = false
    @Published private(set) var automaticallyRevealed = false
    @Published private(set) var manualScrollOffset: CGFloat = 0
    private var scrollMetrics: LyricsScrollMetrics?
    @Published private(set) var isMorphingToTile = false
    @Published private(set) var isTileHovered = false
    private(set) var morphAnimationDuration: TimeInterval = 0.34
    private var acceleratesCollapse = false
    private weak var model: AppModel?
    private var observer: NSObjectProtocol?
    private var pointerTimer: Timer?
    private var scrollMonitors: [Any] = []
    private var isAnimatingFrame = false
    private var frameAnimationGeneration = 0
    private var displayID: CGDirectDisplayID?
    private var dragPointerOffsetY: CGFloat?
    private let verticalPositionKey = "overlayVerticalPositionFraction"

    var overlayTransitionAnimation: Animation {
        isExpanded ? .easeInOut(duration: 0.34) : collapseAnimation
    }

    private var collapseAnimation: Animation {
        acceleratesCollapse
            ? .timingCurve(0.7, 0, 1, 1, duration: morphAnimationDuration)
            : .easeInOut(duration: morphAnimationDuration)
    }

    private static func overlayFrame(for screen: NSScreen) -> CGRect {
        let visible = screen.visibleFrame
        // Keep the right edge aligned to the display while avoiding the menu
        // bar and Dock vertically.
        return CGRect(x: screen.frame.minX, y: visible.minY, width: screen.frame.width, height: visible.height)
    }

    static func frame(in screen: CGRect, verticalFraction: CGFloat = 0.5) -> CGRect {
        let width = screen.width * 0.22
        let height = screen.height / 2
        let fraction = min(1, max(0, verticalFraction))
        let tileTravel = max(0, screen.height - 70)
        let tileCenterY = screen.minY + 35 + tileTravel * fraction
        let y = min(screen.maxY - height, max(screen.minY, tileCenterY - height / 2))
        return CGRect(x: screen.maxX - width, y: y, width: width, height: height)
    }

    static func statusFrame(in screen: CGRect) -> CGRect {
        frame(in: screen)
    }

    static func frame(in screen: CGRect, showingLyrics: Bool, verticalFraction: CGFloat = 0.5) -> CGRect {
        // Keep the expanded panel at its saved position while a refresh swaps
        // lyrics for a loading message. The content may change, but its window
        // frame must not jump to the default status position.
        frame(in: screen, verticalFraction: verticalFraction)
    }

    private static func framesMatch(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.minX - rhs.minX) < 1 && abs(lhs.minY - rhs.minY) < 1
            && abs(lhs.width - rhs.width) < 1 && abs(lhs.height - rhs.height) < 1
    }

    static func collapsedFrame(in screen: CGRect, verticalFraction: CGFloat = 0.5) -> CGRect {
        let fraction = min(1, max(0, verticalFraction))
        let travel = max(0, screen.height - 70)
        return CGRect(x: screen.maxX - 70, y: screen.minY + travel * fraction, width: 70, height: 70)
    }

    static func draggedFrame(_ frame: CGRect, in screen: CGRect, pointerY: CGFloat, pointerOffsetY: CGFloat) -> CGRect {
        let y = min(screen.maxY - frame.height,
                    max(screen.minY, pointerY - pointerOffsetY - frame.height / 2))
        return CGRect(x: screen.maxX - frame.width, y: y, width: frame.width, height: frame.height)
    }

    static func verticalScrollOffset(viewportHeight: CGFloat, cueCenter: CGFloat) -> CGFloat {
        min(0, viewportHeight / 2 - cueCenter)
    }

    static func lyricsOffset(viewportHeight: CGFloat, contentHeight: CGFloat, cueCenter: CGFloat, manualOffset: CGFloat) -> CGFloat {
        let lowestOffset = min(0, viewportHeight - contentHeight)
        let automaticOffset = max(lowestOffset, verticalScrollOffset(viewportHeight: viewportHeight, cueCenter: cueCenter))
        return min(0, max(lowestOffset, automaticOffset + manualOffset))
    }

    static func clampedManualScrollOffset(_ offset: CGFloat, metrics: LyricsScrollMetrics) -> CGFloat {
        let base = lyricsOffset(viewportHeight: metrics.viewportHeight, contentHeight: metrics.contentHeight,
                                cueCenter: metrics.cueCenter, manualOffset: 0)
        let lower = min(0, metrics.viewportHeight - metrics.contentHeight)
        return min(-base, max(lower - base, offset))
    }

    static func isInsideLyricsViewport(_ point: CGPoint, panelFrame: CGRect, headerHeight: CGFloat = menuHeight) -> Bool {
        let bodyHeight = max(0, panelFrame.height - headerHeight * 2)
        return CGRect(x: panelFrame.minX, y: panelFrame.minY + headerHeight, width: panelFrame.width, height: bodyHeight).contains(point)
    }

    init(model: AppModel, releaseChecker: ReleaseUpdateChecker) {
        self.model = model
        panel = LyricsPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.alphaValue = 1; panel.ignoresMouseEvents = false; panel.hidesOnDeactivate = false
        panel.level = .floating; panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        let hosting = NSHostingView(rootView: LyricsOverlayView(model: model, controller: self, releaseChecker: releaseChecker))
        hosting.wantsLayer = true; hosting.layer?.backgroundColor = NSColor.clear.cgColor
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
        displayID = NSScreen.screens.first?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        relocate()
        pointerTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.updatePointerPosition() }
        }
        let overlayWindowNumber = panel.windowNumber
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel, handler: { [weak self] event in
            guard event.windowNumber == overlayWindowNumber else { return event }
            let delta = event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 1 : 40)
            let shouldCapture = MainActor.assumeIsolated {
                guard let self, self.isExpanded, self.model?.hasDisplayableLyrics == true,
                      self.model?.pointerInsideLyricsArea == true || self.model?.lyricsLocked == true else { return false }
                let point = self.panel.convertPoint(toScreen: event.locationInWindow)
                return Self.isInsideLyricsViewport(point, panelFrame: self.panel.frame)
            }
            guard shouldCapture else { return event }
            Task { @MainActor [weak self] in self?.scrollLyrics(by: delta) }
            return nil
        }) {
            scrollMonitors.append(monitor)
        }
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.relocate() }
        }
    }

    func relocate(animated: Bool = false, duration: TimeInterval = 0.34, timingFunction: CAMediaTimingFunction = CAMediaTimingFunction(name: .easeInEaseOut)) {
        guard let screen = NSScreen.screens.first(where: { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == displayID }) ?? NSScreen.screens.first else { return }
        displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        let usableFrame = Self.overlayFrame(for: screen)
        let fraction = savedVerticalFraction
        let target = isExpanded
            ? Self.frame(in: usableFrame, showingLyrics: model?.hasDisplayableLyrics == true, verticalFraction: fraction)
            : Self.collapsedFrame(in: usableFrame, verticalFraction: fraction)
        guard animated else {
            frameAnimationGeneration += 1
            isAnimatingFrame = false
            panel.setFrame(target, display: true)
            updatePointerPosition()
            return
        }
        frameAnimationGeneration += 1
        let animationGeneration = frameAnimationGeneration
        isAnimatingFrame = true
        panel.ignoresMouseEvents = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = timingFunction
            panel.animator().setFrame(target, display: true)
        } completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                self?.finishFrameAnimation(animationGeneration)
            }
        }
        // Window frame animation completions can be dropped when a second
        // expand/collapse starts before the first animation has fully settled.
        // Always restore hit testing for the latest requested frame.
        DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.16) { [weak self] in
            Task { @MainActor [weak self] in
                self?.finishFrameAnimation(animationGeneration)
            }
        }
    }

    private func finishFrameAnimation(_ generation: Int) {
        guard generation == frameAnimationGeneration else { return }
        isAnimatingFrame = false
        if isExpanded { model?.synchronize(animate: false) }
        updatePointerPosition()
    }

    func dragCollapsedTile() {
        guard !isExpanded,
              let screen = NSScreen.screens.first(where: { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == displayID }) ?? NSScreen.screens.first else { return }
        setTileHovered(false)
        let usableFrame = Self.overlayFrame(for: screen)
        let pointerY = NSEvent.mouseLocation.y
        if dragPointerOffsetY == nil { dragPointerOffsetY = pointerY - panel.frame.midY }
        panel.setFrame(Self.draggedFrame(panel.frame, in: usableFrame, pointerY: pointerY,
                                        pointerOffsetY: dragPointerOffsetY ?? 0), display: true)
    }

    func finishCollapsedTileDrag() {
        defer { dragPointerOffsetY = nil }
        guard !isExpanded,
              let screen = NSScreen.screens.first(where: { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == displayID }) ?? NSScreen.screens.first else { return }
        let usableFrame = Self.overlayFrame(for: screen)
        let travel = max(0, usableFrame.height - 70)
        let fraction = travel > 0 ? (panel.frame.minY - usableFrame.minY) / travel : 0.5
        UserDefaults.standard.set(Double(min(1, max(0, fraction))), forKey: verticalPositionKey)
        updatePointerPosition()
    }

    private var savedVerticalFraction: CGFloat {
        guard UserDefaults.standard.object(forKey: verticalPositionKey) != nil else { return 0.5 }
        return min(1, max(0, CGFloat(UserDefaults.standard.double(forKey: verticalPositionKey))))
    }

    private func updatePointerPosition() {
        guard !isAnimatingFrame else { return }
        if isExpanded, dragPointerOffsetY == nil,
           let screen = NSScreen.screens.first(where: { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == displayID }) ?? NSScreen.screens.first,
           !Self.framesMatch(panel.frame, Self.frame(in: Self.overlayFrame(for: screen), showingLyrics: model?.hasDisplayableLyrics == true, verticalFraction: savedVerticalFraction)) {
            relocate(animated: true)
            return
        }
        let mouse = NSEvent.mouseLocation
        let hovering = panel.isVisible && panel.frame.contains(mouse)
        if model?.pointerInsideLyricsArea != hovering { model?.pointerInsideLyricsArea = hovering }
        if hovering && automaticallyRevealed { automaticallyRevealed = false }
        if isExpanded {
            // Keep the expanded panel's full rectangle hit-testable so clicks
            // and scroll input never leak through to windows underneath it.
            panel.ignoresMouseEvents = false
        } else {
            panel.ignoresMouseEvents = false
        }
    }

    func revealLyricsIfNeeded() {
        guard !isExpanded, model?.autoShowLyrics == true, model?.hasDisplayableLyrics == true else { return }
        expand(automatically: true)
    }

    func expand(automatically: Bool = false) {
        guard !isExpanded else { return }
        // Display the current clock position even if a render tick was delayed.
        // Never reconnect or reset the playback clock for a presentation change.
        model?.synchronize(animate: false)
        automaticallyRevealed = automatically
        setTileHovered(false)
        morphAnimationDuration = 0.34
        withAnimation(.easeInOut(duration: 0.34)) {
            isMorphingToTile = false
            isExpanded = true
        }
        relocate(animated: true)
    }

    func collapse() { collapse(duration: 0.34) }

    func collapse(duration: TimeInterval, accelerating: Bool = false) {
        guard isExpanded else { return }
        automaticallyRevealed = false
        isTileHovered = false
        morphAnimationDuration = duration
        acceleratesCollapse = accelerating
        withAnimation(collapseAnimation) {
            isMorphingToTile = true
            isExpanded = false
        }
        let timing = accelerating
            ? CAMediaTimingFunction(controlPoints: 0.7, 0, 1, 1)
            : CAMediaTimingFunction(name: .easeInEaseOut)
        relocate(animated: true, duration: duration, timingFunction: timing)
    }

    func setTileHovered(_ hovered: Bool) {
        guard !isExpanded, isTileHovered != hovered else { return }
        isTileHovered = hovered
    }

    func scrollLyrics(by delta: CGFloat) {
        guard isExpanded, panel.isVisible, delta.isFinite,
              Self.isInsideLyricsViewport(NSEvent.mouseLocation, panelFrame: panel.frame),
              model?.hasDisplayableLyrics == true, let scrollMetrics else { return }
        manualScrollOffset = Self.clampedManualScrollOffset(manualScrollOffset + delta, metrics: scrollMetrics)
    }

    func updateScrollMetrics(_ metrics: LyricsScrollMetrics) {
        scrollMetrics = metrics
        let clamped = Self.clampedManualScrollOffset(manualScrollOffset, metrics: metrics)
        if clamped != manualScrollOffset { manualScrollOffset = clamped }
    }

    func resetLyricsScroll() {
        manualScrollOffset = 0
    }

    func setVisible(_ visible: Bool) {
        if visible { panel.orderFrontRegardless(); updatePointerPosition() }
        else { panel.orderOut(nil); model?.pointerInsideLyricsArea = false; panel.ignoresMouseEvents = true }
    }

    func close() {
        pointerTimer?.invalidate(); pointerTimer = nil
        scrollMonitors.forEach(NSEvent.removeMonitor)
        scrollMonitors.removeAll()
        if let observer { NotificationCenter.default.removeObserver(observer) }
        panel.close()
    }
}
