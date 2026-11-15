import AppKit
import SwiftUI

/// Small uppercase label above a value.
struct MetricLabel: View {
    let text: String
    var size: CGFloat = 11

    var body: some View {
        Text(text)
            .font(Theme.text(size, .semibold))
            .tracking(size * 0.08)
            .foregroundStyle(Theme.label)
            .lineLimit(1)
            .fixedSize()
    }
}

/// Orange pill showing the gear (or ERG offset); pops briefly when it changes.
struct GearPill: View {
    let main: String
    let suffix: String
    let size: CGFloat
    let trigger: Int

    @State private var pop = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: size * 0.07) {
            Text(main)
                .font(Theme.number(size, .heavy))
            Text(suffix)
                .font(Theme.text(size * 0.43, .bold))
                .opacity(0.72)
        }
        .foregroundStyle(Theme.onAccent)
        .fixedSize()
        .padding(.horizontal, size * 0.4)
        .padding(.top, size * 0.1)
        .padding(.bottom, size * 0.13)
        .background(RoundedRectangle(cornerRadius: size * 0.4, style: .continuous).fill(Theme.accent))
        .background(
            RoundedRectangle(cornerRadius: size * 0.4, style: .continuous)
                .stroke(Theme.accent.opacity(pop ? 0.55 : 0.22), lineWidth: size * (pop ? 0.42 : 0.27))
        )
        .scaleEffect(pop ? 1.14 : 1)
        .onChange(of: trigger) {
            withAnimation(.spring(response: 0.18, dampingFraction: 0.55)) { pop = true }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(180))
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { pop = false }
            }
        }
    }
}

struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.midX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

/// ▲ / ▼ in the colour of the grade.
struct GradeArrow: View {
    let grade: Double
    let width: CGFloat

    var body: some View {
        Triangle()
            .fill(Theme.gradeColor(grade))
            .frame(width: width, height: width * 12 / 14)
            .rotationEffect(.degrees(grade < -0.05 ? 180 : 0))
            .accessibilityHidden(true)
    }
}

struct HeartIcon: View {
    let size: CGFloat

    var body: some View {
        Image(systemName: "heart")
            .font(.system(size: size, weight: .bold))
            .foregroundStyle(Theme.heart)
            .accessibilityHidden(true)
    }
}

/// Six small bars, the current power zone lit up.
struct ZoneSegments: View {
    let active: Int?
    let width: CGFloat
    let height: CGFloat
    let spacing: CGFloat

    var body: some View {
        HStack(spacing: spacing) {
            ForEach(0..<6, id: \.self) { i in
                Capsule()
                    .fill(Theme.zoneColor(i))
                    .opacity(i == active ? 1 : 0.28)
                    .frame(width: width, height: height)
            }
        }
        .accessibilityHidden(true)
    }
}

/// Elevation profile as coloured columns, coloured by grade.
struct ProfileBarsView: View {
    let columns: [ProfileColumn]
    /// Position 0…1 of the rider; columns before it are dimmed.
    let marker: Double?
    var spacing: CGFloat = 2
    var minHeight: CGFloat = 5
    var dimAll = false
    var highlightCurrent = true

    var body: some View {
        Canvas { ctx, size in
            guard !columns.isEmpty else { return }
            let n = CGFloat(columns.count)
            let w = Swift.max(0.5, (size.width - spacing * (n - 1)) / n)
            let current = marker.map { Swift.min(columns.count - 1, Int(($0 * Double(columns.count)).rounded(.down))) }
            for (i, c) in columns.enumerated() {
                let h = minHeight + CGFloat(c.norm) * (size.height - minHeight)
                let rect = CGRect(x: CGFloat(i) * (w + spacing), y: size.height - h, width: w, height: h)
                let path = Path(roundedRect: rect, cornerRadius: Swift.min(2, w / 2))
                let isCurrent = highlightCurrent && i == current
                if isCurrent && !dimAll {
                    ctx.drawLayer { layer in
                        layer.addFilter(.shadow(color: .white.opacity(0.85), radius: 5))
                        layer.fill(path, with: .color(.white))
                    }
                    continue
                }
                var alpha = 1.0
                if dimAll {
                    alpha = isCurrent ? 0.6 : 0.22
                } else if let current, i < current {
                    alpha = 0.32
                }
                ctx.fill(path, with: .color((isCurrent ? Color.white : Theme.gradeColor(c.grade)).opacity(alpha)))
            }
        }
        .accessibilityHidden(true)
    }
}

/// Workout as blocks in zone colours, done part dimmed.
struct WorkoutChartView: View {
    let steps: [WorkoutStep]
    let elapsed: TimeInterval
    let zones: PowerZones
    var gap: CGFloat = 2
    var minHeight: CGFloat = 6
    /// Highest fraction of FTP that fills the full height.
    var top: Double = 1.2
    /// Draws a white line in the current block (bar style).
    var inBlockMarker = true
    var trace: [PowerPoint] = []
    var ftp: Double = 250
    var ftpLine = false

    var body: some View {
        Canvas { ctx, size in
            let total = steps.reduce(0) { $0 + $1.duration }
            guard total > 0 else { return }
            let usable = size.width - gap * CGFloat(Swift.max(0, steps.count - 1))
            func height(_ fraction: Double) -> CGFloat {
                minHeight + CGFloat(Swift.min(1, fraction / top)) * (size.height - minHeight)
            }
            var x: CGFloat = 0
            var t: TimeInterval = 0
            for step in steps {
                let w = usable * CGFloat(step.duration / total)
                let start = step.startFraction ?? 0.5
                let end = step.endFraction ?? start
                let h0 = height(start), h1 = height(end)
                var path = Path()
                path.move(to: CGPoint(x: x, y: size.height))
                path.addLine(to: CGPoint(x: x, y: size.height - h0))
                path.addLine(to: CGPoint(x: x + w, y: size.height - h1))
                path.addLine(to: CGPoint(x: x + w, y: size.height))
                path.closeSubpath()
                let color: Color = step.hasTarget ? Theme.zoneColor(zones.index(forFraction: (start + end) / 2)) : Color.white.opacity(0.35)
                let stepEnd = t + step.duration
                if stepEnd <= elapsed {
                    ctx.fill(path, with: .color(color.opacity(0.32)))
                } else if t >= elapsed {
                    ctx.fill(path, with: .color(color))
                } else {
                    let splitX = x + w * CGFloat((elapsed - t) / step.duration)
                    ctx.drawLayer { layer in
                        layer.clip(to: Path(CGRect(x: x, y: 0, width: splitX - x, height: size.height)))
                        layer.fill(path, with: .color(color.opacity(0.32)))
                    }
                    ctx.drawLayer { layer in
                        layer.clip(to: Path(CGRect(x: splitX, y: 0, width: x + w - splitX, height: size.height)))
                        layer.fill(path, with: .color(color))
                    }
                    if inBlockMarker {
                        ctx.fill(Path(CGRect(x: splitX, y: 0, width: Swift.max(1.5, w * 0.015), height: size.height)).intersection(path), with: .color(.white))
                    }
                }
                x += w + gap
                t = stepEnd
            }
            if ftpLine {
                let y = size.height - height(1)
                var line = Path()
                line.move(to: CGPoint(x: 0, y: y))
                line.addLine(to: CGPoint(x: size.width, y: y))
                ctx.stroke(line, with: .color(.white.opacity(0.35)), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
            }
            if trace.count > 1, ftp > 0 {
                var line = Path()
                for (i, p) in trace.enumerated() {
                    let point = CGPoint(x: size.width * CGFloat(p.time / total), y: size.height - height(p.watts / ftp))
                    if i == 0 { line.move(to: point) } else { line.addLine(to: point) }
                }
                ctx.stroke(line, with: .color(.white), style: StrokeStyle(lineWidth: 2, lineJoin: .round))
            }
        }
        .accessibilityHidden(true)
    }
}

/// Dark blurred background for the floating bar.
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        view.appearance = NSAppearance(named: .darkAqua)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
    }
}

/// Row of device status dots ("KICKR · CLICK · PULS · KADENZ").
struct DeviceDots: View {
    @Environment(AppModel.self) private var model
    var size: CGFloat = 13

    var body: some View {
        HStack(spacing: size * 1.5) {
            ForEach(DeviceRole.allCases) { role in
                let status = model.ble.status[role] ?? DeviceStatus()
                if status.state != .notAssigned {
                    HStack(spacing: size * 0.6) {
                        Circle()
                            .fill(status.state.isUsable ? Theme.ok : Theme.warn)
                            .frame(width: size * 0.62, height: size * 0.62)
                            .background(Circle().fill((status.state.isUsable ? Theme.ok : Theme.warn).opacity(0.2)).padding(-size * 0.23))
                        Text(role.shortLabel)
                            .font(Theme.text(size, .semibold))
                            .tracking(size * 0.06)
                            .foregroundStyle(Theme.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(role.title): \(status.state.label)")
                }
            }
        }
    }
}
