import AppKit
import SwiftUI

enum OverlayMetrics {
    static let baseWidth: CGFloat = 980
    /// Height without and with the control row (Spotify and ride buttons).
    static let barHeight: CGFloat = 128
    static let controlsHeight: CGFloat = 172
    static let minWidth: CGFloat = 560
    static let maxWidth: CGFloat = 2400

    static func baseHeight(controls: Bool) -> CGFloat { controls ? controlsHeight : barHeight }
    static func aspect(controls: Bool) -> CGFloat { baseWidth / baseHeight(controls: controls) }
}

/// Content of the floating panel. Scales with the panel width.
struct OverlayBarView: View {
    @Environment(AppModel.self) private var model
    var regions: OverlayHitRegions?

    var body: some View {
        GeometryReader { geo in
            if let engine = model.engine {
                OverlayBar(
                    display: RideDisplay(engine: engine, ftp: model.intervals.effectiveFTP, zones: model.intervals.zones),
                    s: geo.size.width / OverlayMetrics.baseWidth,
                    opacity: model.settings.overlayOpacity,
                    controls: model.settings.showControlRow,
                    regions: regions
                )
            }
        }
        .ignoresSafeArea()
    }
}

/// Variant A of the design: values on top, profile or workout below, optional control row.
struct OverlayBar: View {
    let display: RideDisplay
    let s: CGFloat
    let opacity: Double
    var useMaterial = true
    var showsGrip = true
    var controls = false
    var regions: OverlayHitRegions?

    @State private var hovering = false

    private var engine: RideEngine { display.engine }

    var body: some View {
        VStack(alignment: .leading, spacing: 8 * s) {
            topRow
            bottomRow
            if controls {
                OverlayControlRow(engine: engine, s: s, regions: regions)
            }
        }
        .padding(.horizontal, 24 * s)
        .padding(.vertical, 10 * s)
        .frame(width: OverlayMetrics.baseWidth * s, height: OverlayMetrics.baseHeight(controls: controls) * s, alignment: .topLeading)
        .background {
            ZStack {
                if useMaterial { VisualEffectBackground() }
                Theme.barBase.opacity(useMaterial ? opacity : Swift.max(0.85, opacity))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 20 * s, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20 * s, style: .continuous).strokeBorder(Color.white.opacity(0.07), lineWidth: 1))
        .overlay(alignment: .bottomTrailing) {
            if showsGrip {
                ResizeGrip()
                    .frame(width: 22, height: 22)
                    .opacity(hovering ? 1 : 0.01)
                    .padding(3 * s)
            }
        }
        .onHover { hovering = $0 }
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
    }

    // MARK: Top row

    private var topRow: some View {
        HStack(alignment: .lastTextBaseline, spacing: 0) {
            wattGroup.frame(width: 214 * s, alignment: .leading)
            Spacer(minLength: 4 * s)
            value("RPM", display.rpmText)
            Spacer(minLength: 4 * s)
            value("KM/H", display.kmhText)
            Spacer(minLength: 4 * s)
            heartGroup
            Spacer(minLength: 4 * s)
            pillGroup
            Spacer(minLength: 4 * s)
            slotSix.frame(width: 118 * s, alignment: .leading)
            Spacer(minLength: 4 * s)
            timeGroup
        }
        .frame(height: 70 * s, alignment: .bottom)
    }

    private var wattGroup: some View {
        HStack(alignment: .lastTextBaseline, spacing: 12 * s) {
            VStack(alignment: .leading, spacing: 2 * s) {
                MetricLabel(text: "WATT · 3 S", size: 11 * s)
                HStack(alignment: .firstTextBaseline, spacing: 4 * s) {
                    Text("\(display.watts)")
                        .font(Theme.number(46 * s, .heavy))
                        .foregroundStyle(display.wattColor)
                        .contentTransition(.numericText())
                    Text("W")
                        .font(Theme.text(14 * s))
                        .foregroundStyle(Theme.label)
                }
            }
            VStack(alignment: .leading, spacing: 6 * s) {
                Text(display.chipText)
                    .font(Theme.text(11 * s, .bold))
                    .tracking(0.6 * s)
                    .foregroundStyle(Theme.barBase)
                    .padding(.horizontal, 7 * s)
                    .padding(.vertical, 2 * s)
                    .background(RoundedRectangle(cornerRadius: 6 * s).fill(display.chipColor))
                    .fixedSize()
                ZoneSegments(active: display.isPaused ? nil : display.zoneIndex, width: 9 * s, height: 4 * s, spacing: 3 * s)
            }
            // The zone bars sit on the baseline of the watt number.
            .alignmentGuide(.lastTextBaseline) { d in d[.bottom] }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(display.watts) Watt, \(display.chipText)")
    }

    private func value(_ label: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 2 * s) {
            MetricLabel(text: label, size: 11 * s)
            Text(text)
                .font(Theme.number(38 * s, .bold))
                .foregroundStyle(display.valueColor)
                .fixedSize()
        }
    }

    private var heartGroup: some View {
        VStack(alignment: .leading, spacing: 2 * s) {
            MetricLabel(text: "PULS", size: 11 * s)
            HStack(alignment: .center, spacing: 6 * s) {
                HeartIcon(size: 15 * s)
                Text(display.heartText)
                    .font(Theme.number(38 * s, .bold))
                    .foregroundStyle(display.valueColor)
                    .fixedSize()
            }
        }
    }

    @ViewBuilder
    private var pillGroup: some View {
        VStack(alignment: .leading, spacing: 4 * s) {
            MetricLabel(text: display.showsErgOffset ? "ERG" : "GANG", size: 11 * s)
            if display.showsErgOffset {
                GearPill(main: display.ergOffsetText, suffix: "W", size: 30 * s, trigger: engine.shiftCount)
            } else {
                GearPill(main: display.gearText, suffix: "/24", size: 30 * s, trigger: engine.shiftCount)
            }
        }
        .opacity(display.isPaused ? 0.45 : 1)
    }

    @ViewBuilder
    private var slotSix: some View {
        if display.showsTestAverage {
            VStack(alignment: .leading, spacing: 2 * s) {
                MetricLabel(text: "Ø TEST", size: 11 * s)
                HStack(alignment: .firstTextBaseline, spacing: 4 * s) {
                    Text(display.testAverage.map(String.init) ?? "–")
                        .font(Theme.number(38 * s, .bold))
                        .foregroundStyle(display.testAverage.map { Theme.zoneColor(display.zones.index(watts: Double($0), ftp: Double(display.ftp))) } ?? .white)
                    Text("W")
                        .font(Theme.text(14 * s))
                        .foregroundStyle(Theme.label)
                }
                .fixedSize()
            }
        } else if display.showsTarget {
            VStack(alignment: .leading, spacing: 2 * s) {
                MetricLabel(text: "ZIEL", size: 11 * s)
                HStack(alignment: .firstTextBaseline, spacing: 4 * s) {
                    Text(display.targetText)
                        .font(Theme.number(38 * s, .bold))
                        .foregroundStyle(display.targetColor)
                    Text("W")
                        .font(Theme.text(14 * s))
                        .foregroundStyle(Theme.label)
                }
                .fixedSize()
            }
        } else {
            VStack(alignment: .leading, spacing: 2 * s) {
                MetricLabel(text: "STEIGUNG", size: 11 * s)
                HStack(alignment: .center, spacing: 6 * s) {
                    GradeArrow(grade: engine.gradePercent, width: 14 * s)
                    HStack(alignment: .firstTextBaseline, spacing: 3 * s) {
                        Text(display.gradeText)
                            .font(Theme.number(38 * s, .bold))
                        Text("%")
                            .font(Theme.text(14 * s))
                    }
                    .foregroundStyle(display.gradeColor)
                    .fixedSize()
                }
                .opacity(display.isPaused ? 0.45 : 1)
            }
        }
    }

    private var timeGroup: some View {
        VStack(alignment: .trailing, spacing: 2 * s) {
            MetricLabel(text: "ZEIT", size: 11 * s)
            Text(display.timeText)
                .font(Theme.number(38 * s, .bold))
                .fixedSize()
        }
    }

    // MARK: Bottom row

    @ViewBuilder
    private var bottomRow: some View {
        switch display.bottom {
        case .profile:
            HStack(alignment: .bottom, spacing: 18 * s) {
                ProfileBarsView(columns: engine.barColumns, marker: engine.barMarker, spacing: 2 * s, minHeight: 5 * s)
                    .frame(height: 28 * s)
                distanceText
            }
            .frame(height: 28 * s)
        case .workout:
            HStack(alignment: .bottom, spacing: 18 * s) {
                WorkoutChartView(steps: display.chartSteps, elapsed: engine.movingTime, zones: display.zones, gap: 2 * s, minHeight: 6 * s, top: display.chartTop)
                    .frame(height: 28 * s)
                HStack(alignment: .firstTextBaseline, spacing: 6 * s) {
                    Text(display.stepLeftText)
                        .font(Theme.number(22 * s, .bold))
                    Text(display.workoutRightText)
                        .font(Theme.text(13 * s))
                        .foregroundStyle(engine.testResult == nil ? Theme.label : Theme.accentSoft)
                }
                .fixedSize()
            }
            .frame(height: 28 * s)
        case .paused:
            HStack(alignment: .center, spacing: 12 * s) {
                Image(systemName: "pause.fill")
                    .font(.system(size: 14 * s, weight: .bold))
                    .foregroundStyle(Theme.accent)
                Text("PAUSIERT")
                    .font(Theme.text(15 * s, .bold))
                    .tracking(0.6 * s)
                    .fixedSize()
                Text(display.pauseHint)
                    .font(Theme.text(14 * s, .medium))
                    .foregroundStyle(Theme.label)
                    .fixedSize()
                Group {
                    if engine.config.usesCourse {
                        ProfileBarsView(columns: engine.barColumns, marker: engine.barMarker, spacing: 2 * s, minHeight: 5 * s, dimAll: true)
                    } else {
                        WorkoutChartView(steps: display.workoutSteps, elapsed: engine.movingTime, zones: display.zones, gap: 2 * s, minHeight: 6 * s)
                            .opacity(0.4)
                    }
                }
                .frame(height: 28 * s)
                Text("\(display.distanceValue) \(display.distanceSuffix)")
                    .font(Theme.text(13 * s))
                    .foregroundStyle(Theme.label)
                    .fixedSize()
            }
            .frame(height: 28 * s)
        }
    }

    private var distanceText: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6 * s) {
            Text(display.distanceValue)
                .font(Theme.number(22 * s, .bold))
            Text(display.distanceSuffix)
                .font(Theme.text(13 * s))
                .foregroundStyle(Theme.label)
        }
        .fixedSize()
    }
}

// MARK: - Resizing by the corner

/// Corner handle that resizes the panel while keeping its aspect ratio.
struct ResizeGrip: NSViewRepresentable {
    func makeNSView(context: Context) -> ResizeGripView { ResizeGripView() }
    func updateNSView(_ nsView: ResizeGripView, context: Context) {}
}

final class ResizeGripView: NSView {
    private var startMouse: NSPoint = .zero
    private var startFrame: NSRect = .zero

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: NSCursor.frameResize(position: .bottomRight, directions: .all))
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.withAlphaComponent(0.55).setStroke()
        let path = NSBezierPath()
        path.lineWidth = 1.6
        path.lineCapStyle = .round
        let b = bounds.insetBy(dx: 5, dy: 5)
        for i in 0..<3 {
            let o = CGFloat(i) * 4.5
            path.move(to: NSPoint(x: b.maxX - o - 0.5, y: b.minY))
            path.line(to: NSPoint(x: b.maxX, y: b.minY + o + 0.5))
        }
        path.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        startMouse = NSEvent.mouseLocation
        startFrame = window?.frame ?? .zero
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window, startFrame.height > 0 else { return }
        let p = NSEvent.mouseLocation
        let dx = p.x - startMouse.x
        let dy = startMouse.y - p.y
        let aspect = startFrame.width / startFrame.height
        let delta = abs(dx) >= abs(dy * aspect) ? dx : dy * aspect
        let width = Swift.min(OverlayMetrics.maxWidth, Swift.max(OverlayMetrics.minWidth, startFrame.width + delta))
        let height = width / aspect
        // Keep the top-left corner in place.
        window.setFrame(NSRect(x: startFrame.minX, y: startFrame.maxY - height, width: width, height: height), display: true)
    }

    override func mouseUp(with event: NSEvent) {
        window?.invalidateShadow()
    }
}

// MARK: - Panel

/// Borderless, non-activating panel that floats over full screen videos.
final class OverlayPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(contentRect: contentRect, styleMask: [.borderless, .nonactivatingPanel, .resizable], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isMovableByWindowBackground = false
        isReleasedWhenClosed = false
        setLayout(controls: false)
    }

    func setLayout(controls: Bool) {
        let aspect = OverlayMetrics.aspect(controls: controls)
        contentAspectRatio = NSSize(width: OverlayMetrics.baseWidth, height: OverlayMetrics.baseHeight(controls: controls))
        minSize = NSSize(width: OverlayMetrics.minWidth, height: OverlayMetrics.minWidth / aspect)
        maxSize = NSSize(width: OverlayMetrics.maxWidth, height: OverlayMetrics.maxWidth / aspect)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Hosting view that moves the panel on drag and toggles full screen on double click.
/// Clicks inside the registered regions (the control row) go to the SwiftUI buttons.
final class OverlayHostingView<Content: View>: NSHostingView<Content> {
    var onDoubleClick: (() -> Void)?
    var regions: OverlayHitRegions?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let topLeft = isFlipped ? p : CGPoint(x: p.x, y: bounds.height - p.y)
        if regions?.contains(topLeft) == true {
            super.mouseDown(with: event)
        } else if event.clickCount == 2 {
            onDoubleClick?()
        } else {
            window?.performDrag(with: event)
        }
    }
}

@MainActor
final class OverlayPanelController {
    private let panel: OverlayPanel
    private let model: AppModel
    private let regions = OverlayHitRegions()

    init(model: AppModel) {
        self.model = model
        let controls = model.settings.showControlRow
        let size = NSSize(width: OverlayMetrics.baseWidth, height: OverlayMetrics.baseHeight(controls: controls))
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let origin = NSPoint(x: screen.midX - size.width / 2, y: screen.minY + 40)
        panel = OverlayPanel(contentRect: NSRect(origin: origin, size: size))
        let host = OverlayHostingView(rootView: AnyView(OverlayBarView(regions: regions).environment(model)))
        host.sizingOptions = []
        host.regions = regions
        host.onDoubleClick = { [weak model] in model?.toggleDisplayMode() }
        panel.contentView = host
        panel.setFrameAutosaveName("BikeAppOverlayBar")
        applyLayout()
        observeLayout()
    }

    /// Fits the panel height to the current width when the control row is switched on or off.
    private func applyLayout() {
        let controls = model.settings.showControlRow
        if !controls { regions.interactive.removeAll() }
        panel.setLayout(controls: controls)
        let frame = panel.frame
        let height = (frame.width / OverlayMetrics.aspect(controls: controls)).rounded()
        guard abs(height - frame.height) > 0.5 else { return }
        // Keep the bottom edge in place: the bar usually sits at the bottom of the screen.
        var next = NSRect(x: frame.minX, y: frame.minY, width: frame.width, height: height)
        if let visible = (panel.screen ?? NSScreen.main)?.visibleFrame, next.maxY > visible.maxY {
            next.origin.y = visible.maxY - height
        }
        panel.setFrame(next, display: true)
        panel.invalidateShadow()
    }

    private func observeLayout() {
        withObservationTracking {
            _ = model.settings.showControlRow
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.applyLayout()
                self?.observeLayout()
            }
        }
    }

    func show() {
        panel.orderFrontRegardless()
        panel.invalidateShadow()
    }

    func hide() {
        panel.orderOut(nil)
    }

    func setClickThrough(_ enabled: Bool) {
        panel.ignoresMouseEvents = enabled
    }
}
