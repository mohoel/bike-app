import SwiftUI

/// Display values for the bar and the full screen view, derived from the engine.
@MainActor
struct RideDisplay {
    let engine: RideEngine
    let ftp: Int
    let zones: PowerZones

    enum Bottom {
        case profile
        case workout
        case paused
    }

    var watts: Int { engine.power3s }
    var zoneIndex: Int { zones.index(watts: Double(watts), ftp: Double(ftp)) }
    var isPaused: Bool { engine.phase == .paused || engine.phase == .waiting }

    var compliance: TargetCompliance? {
        guard let target = engine.targetWatts, engine.isWorkout else { return nil }
        return TargetCompliance(watts: Double(watts), target: Double(target))
    }

    var wattColor: Color {
        if isPaused { return Color.white.opacity(0.4) }
        if let compliance { return Theme.complianceColor(compliance) }
        return Theme.zoneColor(zoneIndex)
    }

    var chipText: String {
        if isPaused { return "—" }
        if let compliance { return compliance.label }
        return PowerZones.shortName(zoneIndex)
    }

    var chipColor: Color {
        if isPaused { return Color.white.opacity(0.4) }
        if let compliance { return Theme.complianceColor(compliance) }
        return Theme.zoneColor(zoneIndex)
    }

    var zoneLine: String {
        let percent = ftp > 0 ? Int((Double(watts) / Double(ftp) * 100).rounded()) : 0
        return "\(PowerZones.shortName(zoneIndex)) · \(PowerZones.name(zoneIndex)) · \(percent) % FTP"
    }

    var valueColor: Color { isPaused ? Color.white.opacity(0.45) : .white }

    var rpmText: String { "\(engine.cadence)" }
    var kmhText: String { Fmt.decimal(engine.speed * 3.6, 1) }
    var heartText: String { engine.heartRate.map(String.init) ?? "–" }
    var gearText: String { "\(engine.gearbox.gear)" }
    var ergOffsetText: String { engine.ergOffset >= 0 ? "+\(engine.ergOffset)" : "−\(abs(engine.ergOffset))" }

    /// Slot 6 shows the target instead of the grade while ERG holds the power.
    var showsTarget: Bool { engine.isErgActive && engine.targetWatts != nil }
    var showsErgOffset: Bool { engine.clickAdjustsErgOffset }

    var targetText: String { engine.targetWatts.map(String.init) ?? "–" }
    var targetColor: Color {
        guard let t = engine.targetWatts else { return .white }
        return Theme.zoneColor(zones.index(watts: Double(t), ftp: Double(ftp)))
    }

    var gradeText: String { Fmt.decimal(abs(engine.gradePercent), 1) }
    var gradeColor: Color { Theme.gradeColor(engine.gradePercent) }

    var timeText: String { Fmt.clock(engine.movingTime, hours: !engine.isWorkout) }

    var bottom: Bottom {
        if isPaused { return .paused }
        if engine.isWorkout { return .workout }
        return .profile
    }

    var pauseHint: String {
        if engine.phase == .waiting { return "Tritt an, um zu starten" }
        if engine.manualPause { return "Weiter mit ⌃⌥P" }
        if engine.sensorless { return "Weiter mit ⌃⌥P" }
        return "Tritt an, um weiterzufahren"
    }

    var distanceValue: String { Fmt.km(engine.distance) }

    var distanceSuffix: String {
        switch engine.config.goal {
        case let .distance(meters): return "/ \(Fmt.km(meters)) km"
        case .duration, .workout:
            if let left = engine.remainingTime { return "km · noch \(Fmt.clock(left, hours: false))" }
            return "km"
        }
    }

    var stepLeftText: String {
        guard let p = engine.workoutPosition else { return "0:00" }
        return Fmt.clock(p.remainingInStep, hours: false)
    }

    var nextStepText: String {
        guard let player = engine.player, let p = engine.workoutPosition else { return "" }
        guard let next = player.nextStep(after: p.index) else { return "danach Schluss" }
        if let f = next.startFraction { return "danach \(Int((f * Double(ftp)).rounded())) W" }
        return "danach frei"
    }

    var workoutSteps: [WorkoutStep] { engine.player?.workout.steps ?? [] }

    // MARK: FTP test

    /// "Stufe 7 · FTP ≈ 201 W", "Ø 241 W · FTP ≈ 229 W", "Neue FTP: 229 W" …
    var testInfo: String? {
        guard let plan = engine.config.test else { return nil }
        if let result = engine.testResult { return "Neue FTP: \(result.ftp) W" }
        if engine.movingTime < plan.effortStart {
            let left = Fmt.clock(plan.effortStart - engine.movingTime, hours: false)
            return plan.kind == .ramp ? "Rampe startet in \(left)" : "20 Minuten starten in \(left)"
        }
        let estimate = engine.testEstimate.map { "FTP ≈ \($0) W" } ?? "FTP ≈ …"
        switch plan.kind {
        case .ramp:
            let step = Int((engine.movingTime - plan.effortStart) / 60) + 1
            return "Stufe \(step) · \(estimate)"
        case .twenty:
            return testAverage.map { "Ø \($0) W · \(estimate)" } ?? estimate
        }
    }

    /// Average power of the test effort so far.
    var testAverage: Int? {
        guard let powers = engine.testTracker?.effortPowers, !powers.isEmpty else { return nil }
        return Int((Double(powers.reduce(0, +)) / Double(powers.count)).rounded())
    }

    /// 20-minute effort: slot 6 shows the running average instead of the (flat) grade.
    var showsTestAverage: Bool { engine.config.test?.kind == .twenty && engine.isInTestEffort }

    var workoutRightText: String {
        if let testInfo { return "übrig · \(testInfo)" }
        return "übrig · \(nextStepText)"
    }

    /// True while a ramp is running: its end is open, so there is no fixed remaining time.
    var isOpenRamp: Bool { engine.config.test?.kind == .ramp && engine.testResult == nil }

    /// Steps shown in the charts. A running ramp shows only the next few steps (up to about 130 % FTP).
    var chartSteps: [WorkoutStep] {
        guard isOpenRamp else { return workoutSteps }
        let current = engine.workoutPosition?.index ?? 0
        var shown: [WorkoutStep] = []
        for (i, step) in workoutSteps.enumerated() where step != FTPTestPlan.cooldown {
            guard i <= current + 4 || (step.startFraction ?? 0) <= 1.3 else { break }
            shown.append(step)
        }
        return shown + [FTPTestPlan.cooldown]
    }

    var chartDuration: TimeInterval { chartSteps.reduce(0) { $0 + $1.duration } }

    /// Highest fraction of FTP in the chart (the ramp keeps rising instead of hitting the ceiling).
    var chartTop: Double {
        let highest = chartSteps.compactMap { Swift.max($0.startFraction ?? 0, $0.endFraction ?? 0) }.max() ?? 1
        return Swift.max(1.2, highest * 1.05)
    }
}
