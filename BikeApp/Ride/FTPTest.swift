import Foundation

enum FTPTestKind: String, CaseIterable, Identifiable, Codable {
    case ramp
    case twenty

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ramp: return "Rampentest"
        case .twenty: return "20-Minuten-Test"
        }
    }

    var shortTitle: String {
        switch self {
        case .ramp: return "Rampe"
        case .twenty: return "20 Minuten"
        }
    }

    var detail: String {
        switch self {
        case .ramp:
            return "Nach 5 Minuten Aufwärmen steigt die Leistung jede Minute an, bis du nicht mehr kannst. Der Kickr hält die Watt per ERG. FTP = 75 % deiner besten Minute. Dauer etwa 20–30 Minuten."
        case .twenty:
            return "Geführtes Aufwärmen mit kurzen Antritten, dann 20 Minuten so hart und gleichmäßig wie möglich. Dabei schaltest du selbst. FTP = 95 % deiner 20-Minuten-Leistung. Dauer etwa 56 Minuten."
        }
    }

    /// Share of the test power that is the FTP.
    var factor: Double {
        switch self {
        case .ramp: return 0.75
        case .twenty: return 0.95
        }
    }
}

/// The steps of a test and the part of it that is evaluated.
struct FTPTestPlan: Equatable {
    let kind: FTPTestKind
    /// FTP the targets are based on (the current one).
    let baseFTP: Int
    /// True when the base FTP is a real value (from intervals.icu), not just the default.
    let baseIsKnown: Bool
    let workout: Workout
    let effortStart: TimeInterval
    let effortEnd: TimeInterval
    /// Ramp: watts added per minute.
    let rampStep: Int

    static let cooldown = WorkoutStep.steady(300, 0.4, label: "Ausfahren")

    static func make(_ kind: FTPTestKind, ftp: Int, baseIsKnown: Bool) -> FTPTestPlan {
        let f = Double(Swift.max(80, ftp))
        switch kind {
        case .ramp:
            let warmup: [WorkoutStep] = [.steady(180, 0.45, label: "Aufwärmen"), .steady(120, 0.55, label: "Aufwärmen")]
            let start = Swift.max(50, Int((0.5 * f / 5).rounded()) * 5)
            let step = Swift.max(10, Int((0.06 * f / 5).rounded()) * 5)
            var ramp: [WorkoutStep] = []
            var watts = start
            var n = 1
            while Double(watts) <= 2 * f {
                ramp.append(.steady(60, Double(watts) / f, label: "Rampe · Stufe \(n)"))
                watts += step
                n += 1
            }
            let effortStart = warmup.reduce(0) { $0 + $1.duration }
            let effortEnd = effortStart + ramp.reduce(0) { $0 + $1.duration }
            let workout = Workout(id: "ftp-test-ramp", name: "FTP-Test · Rampe", date: nil, eventId: nil, description: nil, steps: warmup + ramp + [cooldown])
            return FTPTestPlan(kind: kind, baseFTP: ftp, baseIsKnown: baseIsKnown, workout: workout, effortStart: effortStart, effortEnd: effortEnd, rampStep: step)
        case .twenty:
            var steps: [WorkoutStep] = [.steady(600, 0.55, label: "Aufwärmen")]
            for _ in 0..<3 {
                steps.append(.steady(60, 1.0, label: "Antritt"))
                steps.append(.steady(60, 0.55, label: "Locker"))
            }
            steps.append(.steady(300, 1.05, label: "Vorbelastung"))
            steps.append(.steady(300, 0.5, label: "Locker"))
            let effortStart = steps.reduce(0) { $0 + $1.duration }
            steps.append(.free(1200, label: "20 Minuten Vollgas"))
            steps.append(.steady(600, 0.45, label: "Ausfahren"))
            let workout = Workout(id: "ftp-test-20", name: "FTP-Test · 20 Minuten", date: nil, eventId: nil, description: nil, steps: steps)
            return FTPTestPlan(kind: kind, baseFTP: ftp, baseIsKnown: baseIsKnown, workout: workout, effortStart: effortStart, effortEnd: effortStart + 1200, rampStep: 0)
        }
    }

    /// Ramp watts of the minute at a given moving time (nil outside the ramp).
    func rampWatts(at time: TimeInterval) -> Int? {
        guard kind == .ramp, time >= effortStart, time < effortEnd else { return nil }
        let player = WorkoutPlayer(workout: workout)
        guard let f = player.targetFraction(at: time) else { return nil }
        return Int((f * Double(baseFTP)).rounded())
    }

    /// The workout cut at `time` and followed by the cooldown (used when the ramp ends early).
    static func truncated(_ workout: Workout, at time: TimeInterval) -> Workout {
        var steps: [WorkoutStep] = []
        var t: TimeInterval = 0
        for step in workout.steps {
            if t + step.duration <= time {
                steps.append(step)
            } else {
                let done = time - t
                if done >= 1 {
                    var part = step
                    part.duration = done
                    steps.append(part)
                }
                break
            }
            t += step.duration
        }
        var copy = workout
        copy.steps = steps + [cooldown]
        return copy
    }
}

struct FTPTestResult: Equatable {
    var kind: FTPTestKind
    var ftp: Int
    /// Best minute (ramp) or 20-minute average (twenty).
    var basis: Int
    var effortSeconds: Int
    var completed: Bool
    var plausible: Bool
    var reason: String?

    var basisText: String {
        switch kind {
        case .ramp: return "Beste Minute \(basis) W × 75 %"
        case .twenty: return "20-Minuten-Schnitt \(basis) W × 95 %"
        }
    }
}

/// Follows the test effort second by second: best minute, average, end of the ramp.
struct FTPTestTracker: Equatable {
    let plan: FTPTestPlan
    private(set) var effortPowers: [Int] = []
    private(set) var bestMinute: Double = 0
    private(set) var finished = false
    private(set) var result: FTPTestResult?
    private var lowCadence = 0
    private var lowPower = 0

    init(plan: FTPTestPlan) {
        self.plan = plan
    }

    func isInEffort(at time: TimeInterval) -> Bool {
        !finished && time >= plan.effortStart && time < plan.effortEnd
    }

    /// Feeds one second. Returns true when the effort just ended.
    mutating func add(time: TimeInterval, power: Int, cadence: Int, target: Int?) -> Bool {
        guard !finished, time >= plan.effortStart else { return false }
        if time >= plan.effortEnd {
            finish(completed: true)
            return true
        }
        effortPowers.append(Swift.max(0, power))
        if effortPowers.count >= 60 {
            let last = effortPowers.suffix(60)
            bestMinute = Swift.max(bestMinute, Double(last.reduce(0, +)) / 60)
        }
        if plan.kind == .ramp {
            lowCadence = cadence < 50 ? lowCadence + 1 : 0
            if let target, target > 0, Double(power) < 0.7 * Double(target) { lowPower += 1 } else { lowPower = 0 }
            if lowCadence >= 6 || lowPower >= 8 {
                finish(completed: true)
                return true
            }
        }
        return false
    }

    /// The rider ends the effort (ramp: "I'm done"; 20 minutes: abort).
    mutating func endManually() {
        guard !finished else { return }
        finish(completed: plan.kind == .ramp)
    }

    /// Running FTP estimate during the effort.
    var estimate: Int? {
        guard !effortPowers.isEmpty else { return nil }
        switch plan.kind {
        case .ramp:
            let basis = effortPowers.count >= 60 ? bestMinute : Double(effortPowers.reduce(0, +)) / Double(effortPowers.count)
            return Int((basis * plan.kind.factor).rounded())
        case .twenty:
            return Int((Double(effortPowers.reduce(0, +)) / Double(effortPowers.count) * plan.kind.factor).rounded())
        }
    }

    private mutating func finish(completed: Bool) {
        finished = true
        let seconds = effortPowers.count
        let basis: Double
        switch plan.kind {
        case .ramp: basis = seconds >= 60 ? bestMinute : 0
        case .twenty: basis = seconds > 0 ? Double(effortPowers.reduce(0, +)) / Double(seconds) : 0
        }
        let ftp = Int((basis * plan.kind.factor).rounded())
        var reason: String?
        if plan.kind == .ramp, seconds < 240 {
            reason = "Die Rampe war kürzer als 4 Minuten."
        } else if plan.kind == .twenty, seconds < 1140 {
            reason = "Die 20 Minuten wurden nicht zu Ende gefahren."
        } else if ftp < 60 || ftp > 600 {
            reason = "Das Ergebnis liegt außerhalb von 60–600 W."
        } else if plan.baseIsKnown, Double(ftp) < 0.6 * Double(plan.baseFTP) || Double(ftp) > 1.5 * Double(plan.baseFTP) {
            reason = "Das Ergebnis weicht stark von deiner bisherigen FTP (\(plan.baseFTP) W) ab."
        }
        result = FTPTestResult(kind: plan.kind, ftp: ftp, basis: Int(basis.rounded()), effortSeconds: seconds,
                               completed: completed && reason == nil, plausible: reason == nil, reason: reason)
    }
}
