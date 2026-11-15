import Foundation

enum DisplayMode: String, CaseIterable, Identifiable {
    case bar
    case fullscreen

    var id: String { rawValue }
    var title: String { self == .bar ? "Leiste" : "Vollbild" }
}

enum GoalKind: String, CaseIterable, Identifiable {
    case distance
    case duration

    var id: String { rawValue }
    var title: String { self == .distance ? "Distanz" : "Dauer" }
}

enum SessionGoal: Equatable {
    case distance(meters: Double)
    case duration(seconds: TimeInterval)
    case workout
}

/// How a structured workout drives the trainer.
enum WorkoutMode: String, CaseIterable, Identifiable {
    case ergOffset
    case ergGears
    case simTargets

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ergOffset: return "ERG · Click ±5 W"
        case .ergGears: return "ERG · Click = Gang"
        case .simTargets: return "Sim mit Zielen"
        }
    }

    var detail: String {
        switch self {
        case .ergOffset:
            return "Der Kickr hält die Zielwatt. Mit Click + und − verschiebst du die Intensität in 5-W-Schritten."
        case .ergGears:
            return "Der Kickr hält die Zielwatt. Click schaltet Gänge, die in Freifahrt-Abschnitten wirken."
        case .simTargets:
            return "Kein ERG: Du fährst das zufällige Höhenprofil und schaltest selbst, die Ziele werden nur angezeigt."
        }
    }

    var usesERG: Bool { self != .simTargets }
}

struct SessionConfig {
    var name: String
    var courseTitle: String
    var gradeRange: GradeRange
    var seed: UInt64
    var goal: SessionGoal
    var workout: Workout?
    var workoutMode: WorkoutMode
    /// "Hügelig" etc., used for the activity name.
    var presetTitle: String = ""
    /// Set for FTP tests; the workout is the test's steps.
    var test: FTPTestPlan?

    /// True when the course profile matters for resistance and display.
    var usesCourse: Bool {
        guard workout != nil else { return true }
        return workoutMode == .simTargets
    }
}

extension SessionGoal {
    /// Step for quick goal changes: 5 km or 5 minutes.
    static let distanceStep: Double = 5000
    static let durationStep: TimeInterval = 300

    var kind: GoalKind? {
        switch self {
        case .distance: return .distance
        case .duration: return .duration
        case .workout: return nil
        }
    }

    var label: String {
        switch self {
        case let .distance(meters): return "\(Fmt.km(meters)) km"
        case let .duration(seconds): return "\(Int((seconds / 60).rounded())) min"
        case .workout: return "Workout"
        }
    }
}
