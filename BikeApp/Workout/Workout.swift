import Foundation

struct WorkoutStep: Equatable {
    enum Kind: Equatable {
        case steady
        case ramp
        case free
    }

    var duration: TimeInterval
    var kind: Kind
    /// Fraction of FTP at the start of the step (nil for free ride).
    var startFraction: Double?
    /// Fraction of FTP at the end of the step (equals start for steady steps).
    var endFraction: Double?
    var label: String?

    static func steady(_ duration: TimeInterval, _ fraction: Double, label: String? = nil) -> WorkoutStep {
        WorkoutStep(duration: duration, kind: .steady, startFraction: fraction, endFraction: fraction, label: label)
    }

    static func ramp(_ duration: TimeInterval, from start: Double, to end: Double, label: String? = nil) -> WorkoutStep {
        WorkoutStep(duration: duration, kind: .ramp, startFraction: start, endFraction: end, label: label)
    }

    static func free(_ duration: TimeInterval, label: String? = nil) -> WorkoutStep {
        WorkoutStep(duration: duration, kind: .free, startFraction: nil, endFraction: nil, label: label)
    }

    /// Target as fraction of FTP at `t` seconds into the step.
    func fraction(at t: TimeInterval) -> Double? {
        guard let start = startFraction else { return nil }
        let end = endFraction ?? start
        guard kind == .ramp, duration > 0 else { return start }
        let p = Swift.min(1, Swift.max(0, t / duration))
        return start + (end - start) * p
    }

    var hasTarget: Bool { startFraction != nil }
}

struct Workout: Identifiable, Equatable {
    var id: String
    var name: String
    var date: Date?
    /// intervals.icu calendar event, used to pair the uploaded ride.
    var eventId: Int?
    var description: String?
    var steps: [WorkoutStep]

    var duration: TimeInterval { steps.reduce(0) { $0 + $1.duration } }
}

/// Answers "where am I in the workout" for a given moving time.
struct WorkoutPlayer: Equatable {
    struct Position: Equatable {
        var index: Int
        var step: WorkoutStep
        var stepStart: TimeInterval
        var timeInStep: TimeInterval
        var remainingInStep: TimeInterval
    }

    let workout: Workout
    private let starts: [TimeInterval]

    init(workout: Workout) {
        self.workout = workout
        var t: TimeInterval = 0
        var starts: [TimeInterval] = []
        for step in workout.steps {
            starts.append(t)
            t += step.duration
        }
        self.starts = starts
    }

    var duration: TimeInterval { workout.duration }

    func position(at time: TimeInterval) -> Position? {
        guard !workout.steps.isEmpty, time < duration else { return nil }
        let t = Swift.max(0, time)
        var index = workout.steps.count - 1
        for (i, start) in starts.enumerated() where start + workout.steps[i].duration > t {
            index = i
            break
        }
        let step = workout.steps[index]
        let inStep = t - starts[index]
        return Position(index: index, step: step, stepStart: starts[index], timeInStep: inStep, remainingInStep: step.duration - inStep)
    }

    func targetFraction(at time: TimeInterval) -> Double? {
        guard let p = position(at: time) else { return nil }
        return p.step.fraction(at: p.timeInStep)
    }

    func nextStep(after index: Int) -> WorkoutStep? {
        let next = index + 1
        return next < workout.steps.count ? workout.steps[next] : nil
    }

    func stepStart(_ index: Int) -> TimeInterval { starts[index] }

    /// Number of the current interval among steps with the same target, e.g. "2 / 3".
    func repetition(of index: Int) -> (current: Int, total: Int)? {
        let step = workout.steps[index]
        guard step.hasTarget else { return nil }
        let same = workout.steps.enumerated().filter { $0.element.startFraction == step.startFraction && $0.element.endFraction == step.endFraction && $0.element.duration == step.duration }
        guard same.count > 1 else { return nil }
        let current = (same.firstIndex { $0.offset == index } ?? 0) + 1
        return (current, same.count)
    }
}
