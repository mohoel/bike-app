import AppKit
import SwiftUI

enum FullscreenMetrics {
    static let width: CGFloat = 1440
    static let height: CGFloat = 900
}

/// Full screen dashboard; the 1440×900 design scales to any window size.
struct FullscreenRideView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        GeometryReader { geo in
            let s = Swift.min(geo.size.width / FullscreenMetrics.width, geo.size.height / FullscreenMetrics.height)
            ZStack {
                Theme.background
                if let engine = model.engine {
                    FullscreenRide(display: RideDisplay(engine: engine, ftp: model.intervals.effectiveFTP, zones: model.intervals.zones), s: s)
                        .frame(width: FullscreenMetrics.width * s, height: FullscreenMetrics.height * s)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .ignoresSafeArea()
        .environment(\.colorScheme, .dark)
    }
}

struct FullscreenRide: View {
    let display: RideDisplay
    let s: CGFloat

    private var engine: RideEngine { display.engine }

    var body: some View {
        VStack(spacing: 0) {
            header
            Spacer(minLength: 0)
            if engine.isWorkout { workoutHero } else { rideHero }
            Spacer(minLength: 0)
            if engine.isWorkout { workoutSection } else { profileSection }
            Spacer(minLength: 0)
            footer
        }
        .padding(.top, 44 * s)
        .padding(.bottom, 48 * s)
        .padding(.horizontal, 64 * s)
        .foregroundStyle(.white)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 14 * s) {
            if let plan = engine.config.test {
                chip("FTP-TEST", color: Theme.onAccent, background: Theme.accent)
                Text(plan.kind.title)
                    .font(Theme.text(20 * s))
                    .lineLimit(1)
                if let info = display.testInfo {
                    Text(info)
                        .font(Theme.text(16 * s, .semibold))
                        .foregroundStyle(engine.testResult == nil ? Theme.secondary : Theme.accentSoft)
                }
            } else if engine.isWorkout {
                chip("INTERVALS.ICU", color: Theme.intervals, background: Theme.chip)
                Text(engine.config.name)
                    .font(Theme.text(20 * s))
                    .lineLimit(1)
                chip(engine.config.workoutMode.title.uppercased(), color: Theme.accentSoft, background: Theme.accent.opacity(0.16))
            } else {
                chip(display.isPaused ? "PAUSE" : "FREIE FAHRT", color: Theme.accentSoft, background: Theme.chip)
                Text(engine.config.courseTitle)
                    .font(Theme.text(20 * s))
                    .lineLimit(1)
                if case let .distance(meters) = engine.config.goal {
                    Text("\(Fmt.km(meters)) km")
                        .font(Theme.text(16 * s, .medium))
                        .foregroundStyle(Theme.secondary)
                }
            }
            Spacer(minLength: 0)
            DeviceDots(size: 13 * s)
        }
        .frame(height: 40 * s)
    }

    private func chip(_ text: String, color: Color, background: Color) -> some View {
        Text(text)
            .font(Theme.text(12 * s, .bold))
            .tracking(0.9 * s)
            .foregroundStyle(color)
            .padding(.horizontal, 10 * s)
            .padding(.vertical, 5 * s)
            .background(RoundedRectangle(cornerRadius: 8 * s).fill(background))
            .fixedSize()
    }

    // MARK: Hero

    private var bigWatts: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10 * s) {
            Text("\(display.watts)")
                .font(Theme.number(196 * s, .heavy))
                .foregroundStyle(display.wattColor)
                .contentTransition(.numericText())
                .frame(height: 168 * s)
            Text("W")
                .font(Theme.text(36 * s))
                .foregroundStyle(Theme.label)
        }
        .fixedSize()
    }

    private var rideHero: some View {
        HStack(spacing: 40 * s) {
            VStack(alignment: .leading, spacing: 14 * s) {
                MetricLabel(text: "WATT · 3 S", size: 14 * s)
                bigWatts
                ZoneSegments(active: display.isPaused ? nil : display.zoneIndex, width: 64 * s, height: 10 * s, spacing: 6 * s)
                Text(display.zoneLine)
                    .font(Theme.text(18 * s))
                    .foregroundStyle(display.isPaused ? Theme.secondary : Theme.zoneColor(display.zoneIndex))
            }
            .frame(width: 500 * s, alignment: .leading)

            Grid(horizontalSpacing: 16 * s, verticalSpacing: 16 * s) {
                GridRow {
                    tile("TRITTFREQUENZ") { number(display.rpmText, unit: "rpm") }
                    tile("GESCHWINDIGKEIT") { number(display.kmhText, unit: "km/h") }
                    tile("PULS") { heartValue }
                }
                GridRow {
                    tile("GANG") { gearPill(size: 56 * s) }
                    tile("STEIGUNG") { gradeValue }
                    tile("ZEIT") { number(display.timeText, unit: nil) }
                }
            }
        }
        .frame(height: 304 * s)
    }

    private var workoutHero: some View {
        HStack(spacing: 40 * s) {
            VStack(alignment: .leading, spacing: 14 * s) {
                MetricLabel(text: "WATT · 3 S", size: 14 * s)
                bigWatts
                HStack(spacing: 14 * s) {
                    if let compliance = display.compliance {
                        Text(compliance.label)
                            .font(Theme.text(13 * s, .bold))
                            .tracking(0.8 * s)
                            .foregroundStyle(Theme.barBase)
                            .padding(.horizontal, 10 * s)
                            .padding(.vertical, 4 * s)
                            .background(RoundedRectangle(cornerRadius: 8 * s).fill(Theme.complianceColor(compliance)))
                            .fixedSize()
                        Text("Ziel \(display.targetText) W")
                            .font(Theme.text(22 * s, .bold))
                            .foregroundStyle(display.targetColor)
                        if engine.config.workoutMode == .ergOffset, engine.ergOffset != 0 {
                            Text("\(display.ergOffsetText) W")
                                .font(Theme.text(15 * s, .medium))
                                .foregroundStyle(Theme.secondary)
                        }
                    } else {
                        Text("Freie Fahrt")
                            .font(Theme.text(22 * s, .bold))
                            .foregroundStyle(Theme.secondary)
                    }
                }
            }
            .frame(width: 470 * s, alignment: .leading)

            VStack(alignment: .leading, spacing: 14 * s) {
                MetricLabel(text: intervalLabel, size: 14 * s)
                Text(display.stepLeftText)
                    .font(Theme.number(150 * s, .heavy))
                    .frame(height: 132 * s)
                    .fixedSize()
                progressBar(stepProgress, color: stepColor, height: 10 * s)
                Text(stepDescription)
                    .font(Theme.text(16 * s, .medium))
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
            }
            .frame(width: 380 * s, alignment: .leading)

            Grid(horizontalSpacing: 16 * s, verticalSpacing: 16 * s) {
                GridRow {
                    tile("RPM") { number(display.rpmText, unit: nil) }
                    tile("PULS") { heartValue(unit: nil) }
                }
                GridRow {
                    if engine.isTest {
                        tile(engine.testResult == nil ? "FTP ≈" : "NEUE FTP") {
                            HStack(alignment: .firstTextBaseline, spacing: 6 * s) {
                                Text(engine.testEstimate.map(String.init) ?? "–")
                                    .font(Theme.number(56 * s, .bold))
                                    .foregroundStyle(Theme.accent)
                                Text("W").font(Theme.text(16 * s)).foregroundStyle(Theme.label)
                            }
                        }
                    } else if engine.config.usesCourse {
                        tile("STEIGUNG") { gradeValue }
                    } else {
                        tile("KM/H") { number(display.kmhText, unit: nil) }
                    }
                    tile(display.showsErgOffset ? "ERG-OFFSET" : "GANG") { gearPill(size: 44 * s) }
                }
            }
        }
        .frame(height: 304 * s)
    }

    private func tile<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            MetricLabel(text: label, size: 13 * s)
            Spacer(minLength: 0)
            content()
        }
        .padding(.horizontal, 24 * s)
        .padding(.vertical, 20 * s)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 20 * s, style: .continuous).fill(Theme.tile))
    }

    private func number(_ text: String, unit: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6 * s) {
            Text(text)
                .font(Theme.number(64 * s, .bold))
                .foregroundStyle(display.valueColor)
            if let unit {
                Text(unit)
                    .font(Theme.text(16 * s))
                    .foregroundStyle(Theme.label)
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.6)
    }

    private var heartValue: some View {
        heartValue(unit: "bpm")
    }

    private func heartValue(unit: String?) -> some View {
        HStack(alignment: .center, spacing: 10 * s) {
            HeartIcon(size: 26 * s)
            number(display.heartText, unit: unit)
        }
    }

    private var gradeValue: some View {
        HStack(alignment: .center, spacing: 10 * s) {
            GradeArrow(grade: engine.gradePercent, width: 24 * s)
            HStack(alignment: .firstTextBaseline, spacing: 4 * s) {
                Text(display.gradeText)
                    .font(Theme.number(64 * s, .bold))
                Text("%")
                    .font(Theme.text(20 * s))
            }
            .foregroundStyle(display.gradeColor)
        }
    }

    @ViewBuilder
    private func gearPill(size: CGFloat) -> some View {
        if display.showsErgOffset {
            GearPill(main: display.ergOffsetText, suffix: "W", size: size, trigger: engine.shiftCount)
        } else {
            GearPill(main: display.gearText, suffix: "/24", size: size, trigger: engine.shiftCount)
        }
    }

    // MARK: Workout details

    private var intervalLabel: String {
        guard let p = engine.workoutPosition, let player = engine.player else { return "ABSCHNITT" }
        if engine.isTest, let label = p.step.label { return "\(label.uppercased()) · NOCH" }
        if let rep = player.repetition(of: p.index) { return "INTERVALL \(rep.current) / \(rep.total) · NOCH" }
        return "ABSCHNITT \(p.index + 1) / \(player.workout.steps.count) · NOCH"
    }

    private var stepProgress: Double {
        guard let p = engine.workoutPosition, p.step.duration > 0 else { return 0 }
        return p.timeInStep / p.step.duration
    }

    private var stepColor: Color {
        guard let p = engine.workoutPosition, let f = p.step.fraction(at: p.timeInStep) else { return Color.white.opacity(0.5) }
        return Theme.zoneColor(display.zones.index(forFraction: f))
    }

    private var stepDescription: String {
        guard let p = engine.workoutPosition else { return "" }
        let duration = Fmt.clock(p.step.duration, hours: false)
        let name = p.step.label ?? stepName(p.step)
        if let a = p.step.startFraction {
            let b = p.step.endFraction ?? a
            let pct = a == b ? "\(Int((a * 100).rounded())) %" : "\(Int((a * 100).rounded()))–\(Int((b * 100).rounded())) %"
            return "\(name) · \(duration) bei \(pct) FTP"
        }
        return "\(name) · \(duration)"
    }

    private func stepName(_ step: WorkoutStep) -> String {
        guard let f = step.startFraction else { return "Freie Fahrt" }
        if step.kind == .ramp { return "Rampe" }
        return PowerZones.name(display.zones.index(forFraction: f))
    }

    private var nextStepDescription: (text: String, color: Color)? {
        guard let player = engine.player, let p = engine.workoutPosition, let next = player.nextStep(after: p.index) else { return nil }
        let name = next.label ?? stepName(next)
        let duration = Fmt.clock(next.duration, hours: false)
        if let f = next.startFraction {
            return ("\(name) · \(duration) · \(Int((f * Double(display.ftp)).rounded())) W", Theme.zoneColor(display.zones.index(forFraction: f)))
        }
        return ("\(name) · \(duration)", Color.white.opacity(0.4))
    }

    // MARK: Profile

    private var profileSection: some View {
        VStack(alignment: .leading, spacing: 14 * s) {
            HStack {
                HStack(spacing: 18 * s) {
                    MetricLabel(text: "HÖHENPROFIL", size: 13 * s)
                    Text("↑ \(Int(engine.ascent.rounded())) hm")
                        .font(Theme.text(16 * s))
                    HStack(spacing: 0) {
                        Text("Nächster Kilometer Ø ")
                            .foregroundStyle(Theme.secondary)
                        Text("\(Fmt.signedGrade(engine.nextKilometerGrade)) %")
                            .fontWeight(.bold)
                            .foregroundStyle(Theme.gradeColor(engine.nextKilometerGrade))
                    }
                    .font(Theme.text(16 * s, .medium))
                }
                Spacer(minLength: 0)
                HStack(spacing: 18 * s) {
                    ForEach(Theme.gradeLegend, id: \.label) { item in
                        HStack(spacing: 7 * s) {
                            RoundedRectangle(cornerRadius: 3 * s).fill(item.color).frame(width: 10 * s, height: 10 * s)
                            Text(item.label)
                                .font(Theme.text(13 * s))
                                .foregroundStyle(Theme.secondary)
                        }
                    }
                }
            }
            GeometryReader { geo in
                let x = geo.size.width * CGFloat(engine.fullMarker)
                ZStack(alignment: .bottomLeading) {
                    ProfileBarsView(columns: engine.fullColumns, marker: engine.fullMarker, spacing: 1 * s, minHeight: 14 * s, highlightCurrent: false)
                        .frame(height: 186 * s)
                    Rectangle()
                        .fill(Color.white)
                        .frame(width: 2 * s, height: 236 * s)
                        .shadow(color: .white.opacity(0.8), radius: 6 * s)
                        .offset(x: x - 1 * s)
                    markerBubble("\(Fmt.km(engine.distance)) km · \(Int(engine.altitude.rounded())) m")
                        .position(x: Swift.min(geo.size.width - 70 * s, Swift.max(70 * s, x)), y: 12 * s)
                }
            }
            .frame(height: 236 * s)
            axisLabels(profileAxis)
        }
    }

    private var profileAxis: [String] {
        let window = engine.fullWindow
        let start = window.lowerBound / 1000, end = window.upperBound / 1000
        return (0...6).map { i in
            let km = start + (end - start) * Double(i) / 6
            let text = km.rounded() == km ? "\(Int(km))" : Fmt.decimal(km, 1)
            return i == 0 || i == 6 ? "\(text) km" : text
        }
    }

    // MARK: Workout chart

    private var workoutSection: some View {
        VStack(alignment: .leading, spacing: 14 * s) {
            HStack {
                HStack(spacing: 18 * s) {
                    MetricLabel(text: engine.isTest ? "TEST" : "WORKOUT", size: 13 * s)
                    Text(display.isOpenRamp
                         ? Fmt.clock(engine.movingTime, hours: false)
                         : "\(Fmt.clock(engine.movingTime, hours: false)) / \(Fmt.clock(engine.player?.duration ?? 0, hours: false))")
                        .font(Theme.text(16 * s))
                }
                Spacer(minLength: 0)
                if let next = nextStepDescription {
                    HStack(spacing: 10 * s) {
                        MetricLabel(text: "DANACH", size: 13 * s)
                        RoundedRectangle(cornerRadius: 3 * s).fill(next.color).frame(width: 10 * s, height: 10 * s)
                        Text(next.text)
                            .font(Theme.text(16 * s, .bold))
                    }
                }
            }
            GeometryReader { geo in
                let total = display.chartDuration
                let x = geo.size.width * CGFloat(Swift.min(1, engine.movingTime / Swift.max(1, total)))
                ZStack(alignment: .bottomLeading) {
                    WorkoutChartView(steps: display.chartSteps, elapsed: engine.movingTime, zones: display.zones, gap: 3 * s, minHeight: 8 * s, top: display.chartTop, inBlockMarker: false, trace: engine.powerTrace, ftp: Double(display.ftp), ftpLine: true)
                        .frame(height: 236 * s)
                    Rectangle()
                        .fill(Color.white)
                        .frame(width: 2 * s, height: 236 * s)
                        .shadow(color: .white.opacity(0.8), radius: 6 * s)
                        .offset(x: x - 1 * s)
                    markerBubble(Fmt.clock(engine.movingTime, hours: false))
                        .position(x: Swift.min(geo.size.width - 40 * s, Swift.max(40 * s, x)), y: 12 * s)
                    Text("FTP \(display.ftp) W")
                        .font(Theme.text(12 * s))
                        .tracking(0.7 * s)
                        .foregroundStyle(Theme.label)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .offset(y: -(8 * s + (236 - 8) * s / CGFloat(display.chartTop) + 6 * s))
                }
            }
            .frame(height: 236 * s)
            axisLabels(workoutAxis)
        }
    }

    private var workoutAxis: [String] {
        let minutes = display.chartDuration / 60
        return (0...6).map { i in
            let m = Int((minutes * Double(i) / 6).rounded())
            return i == 0 || i == 6 ? "\(m) min" : "\(m)"
        }
    }

    // MARK: Shared

    private func markerBubble(_ text: String) -> some View {
        Text(text)
            .font(Theme.text(14 * s, .bold))
            .foregroundStyle(Theme.background)
            .padding(.horizontal, 10 * s)
            .padding(.vertical, 4 * s)
            .background(Capsule().fill(Color.white))
            .fixedSize()
    }

    private func axisLabels(_ labels: [String]) -> some View {
        HStack {
            ForEach(Array(labels.enumerated()), id: \.offset) { i, label in
                Text(label)
                if i < labels.count - 1 { Spacer(minLength: 0) }
            }
        }
        .font(Theme.text(13 * s))
        .foregroundStyle(Color.white.opacity(0.55))
    }

    private func progressBar(_ value: Double, color: Color, height: CGFloat) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.track)
                Capsule().fill(color).frame(width: geo.size.width * CGFloat(Swift.min(1, Swift.max(0, value))))
            }
        }
        .frame(height: height)
    }

    private var footer: some View {
        HStack(spacing: 20 * s) {
            Text(footerLeft)
                .font(Theme.number(28 * s, .bold))
                .fixedSize()
            progressBar(engine.progress, color: Theme.accent, height: 10 * s)
            Text(footerRight)
                .font(Theme.text(18 * s))
                .foregroundStyle(Theme.secondary)
                .fixedSize()
        }
        .frame(height: 36 * s)
    }

    private var footerLeft: String {
        switch engine.config.goal {
        case .distance: return "\(Fmt.km(engine.distance)) km"
        case .duration, .workout: return Fmt.clock(engine.movingTime, hours: false)
        }
    }

    private var footerRight: String {
        if display.isOpenRamp { return engine.isInTestEffort ? "bis du nicht mehr kannst" : "Rampe folgt" }
        if let left = engine.remainingDistance { return "noch \(Fmt.km(left)) km" }
        if let left = engine.remainingTime { return "noch \(Fmt.clock(left, hours: false))" }
        return ""
    }
}

// MARK: - Window

@MainActor
final class FullscreenWindowController: NSObject, NSWindowDelegate {
    private let model: AppModel
    private var window: NSWindow?
    private var closingByApp = false

    init(model: AppModel) {
        self.model = model
    }

    func show() {
        let window = self.window ?? makeWindow()
        self.window = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        if !window.styleMask.contains(.fullScreen) {
            window.toggleFullScreen(nil)
        }
    }

    func close() {
        guard let window, window.isVisible else { return }
        closingByApp = true
        if window.styleMask.contains(.fullScreen) {
            window.toggleFullScreen(nil)
        } else {
            window.orderOut(nil)
            closingByApp = false
        }
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: FullscreenMetrics.width, height: FullscreenMetrics.height),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Bike App – Vollbild"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = NSColor(srgbRed: 0x0B / 255, green: 0x0D / 255, blue: 0x12 / 255, alpha: 1)
        window.collectionBehavior = [.fullScreenPrimary]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: FullscreenRideView().environment(model))
        window.center()
        return window
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        window?.orderOut(nil)
        if closingByApp {
            closingByApp = false
        } else {
            // Left full screen with Esc or the green button: back to the bar.
            model.setDisplayMode(.bar)
        }
    }

    func windowWillClose(_ notification: Notification) {
        if !closingByApp { model.setDisplayMode(.bar) }
    }
}
