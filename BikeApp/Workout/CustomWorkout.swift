import Foundation
import Observation

/// One block of a workout built in the app: a step or a repeated group of steps.
struct WorkoutBlock: Codable, Identifiable, Equatable {
    enum Kind: String, Codable, CaseIterable, Identifiable {
        case steady
        case ramp
        case free
        case repeats

        var id: String { rawValue }

        var title: String {
            switch self {
            case .steady: return "Konstant"
            case .ramp: return "Rampe"
            case .free: return "Frei"
            case .repeats: return "Wiederholung"
            }
        }
    }

    var id = UUID()
    var kind: Kind
    /// Seconds; unused for repeats.
    var duration: TimeInterval = 300
    /// Percent of FTP at the start (and for steady steps).
    var startPercent: Int = 75
    /// Percent of FTP at the end of a ramp.
    var endPercent: Int = 75
    var label: String = ""
    var reps: Int = 3
    /// Steps of a repeat group (one level, no nested repeats).
    var children: [WorkoutBlock] = []

    static func steady(_ minutes: Double, _ percent: Int, _ label: String = "") -> WorkoutBlock {
        WorkoutBlock(kind: .steady, duration: minutes * 60, startPercent: percent, endPercent: percent, label: label)
    }

    static func ramp(_ minutes: Double, _ from: Int, _ to: Int, _ label: String = "") -> WorkoutBlock {
        WorkoutBlock(kind: .ramp, duration: minutes * 60, startPercent: from, endPercent: to, label: label)
    }

    static func free(_ minutes: Double, _ label: String = "") -> WorkoutBlock {
        WorkoutBlock(kind: .free, duration: minutes * 60, label: label)
    }

    static func repeats(_ reps: Int, _ children: [WorkoutBlock]) -> WorkoutBlock {
        WorkoutBlock(kind: .repeats, reps: reps, children: children)
    }

    /// Same block with fresh ids (for duplicating).
    func copy() -> WorkoutBlock {
        var c = self
        c.id = UUID()
        c.children = children.map { $0.copy() }
        return c
    }

    var totalDuration: TimeInterval {
        kind == .repeats ? Double(Swift.max(1, reps)) * children.reduce(0) { $0 + $1.totalDuration } : duration
    }

    var steps: [WorkoutStep] {
        let text = label.trimmingCharacters(in: .whitespaces).isEmpty ? nil : label
        switch kind {
        case .steady:
            return [.steady(duration, Double(startPercent) / 100, label: text)]
        case .ramp:
            return [.ramp(duration, from: Double(startPercent) / 100, to: Double(endPercent) / 100, label: text)]
        case .free:
            return [.free(duration, label: text)]
        case .repeats:
            let inner = children.flatMap(\.steps)
            return Array(repeating: inner, count: Swift.max(1, reps)).flatMap { $0 }
        }
    }
}

/// A workout created in the app.
struct CustomWorkout: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var notes: String = ""
    var blocks: [WorkoutBlock]
    var modified = Date()

    static let idPrefix = "custom-"

    var steps: [WorkoutStep] {
        blocks.flatMap(\.steps).filter { $0.duration > 0 }
    }

    var duration: TimeInterval { steps.reduce(0) { $0 + $1.duration } }

    var asWorkout: Workout {
        Workout(id: Self.idPrefix + id.uuidString, name: name, date: nil, eventId: nil,
                description: notes.isEmpty ? nil : notes, steps: steps)
    }

    var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && duration > 0
    }

    /// Training stress estimate (free steps count as 50 % FTP).
    var stressScore: Int {
        var sum = 0.0
        for step in steps {
            let a = step.startFraction ?? 0.5
            let b = step.endFraction ?? a
            // Mean of the squared intensity over a linear ramp.
            sum += step.duration * (a * a + a * b + b * b) / 3
        }
        return Int((sum / 3600 * 100).rounded())
    }

    /// Mean intensity (fraction of FTP) weighted by time.
    var intensityFactor: Double {
        let total = duration
        guard total > 0 else { return 0 }
        return (Double(stressScore) / 100 * 3600 / total).squareRoot()
    }

    /// Workout text in intervals.icu syntax, e.g. "3x\n- 10m 90%\n- 5m 55%".
    var intervalsText: String {
        func time(_ seconds: TimeInterval) -> String {
            let s = Int(seconds.rounded())
            if s % 60 == 0 { return "\(s / 60)m" }
            if s < 60 { return "\(s)s" }
            return "\(s / 60)m\(s % 60)s"
        }
        func line(_ b: WorkoutBlock) -> String {
            let label = b.label.trimmingCharacters(in: .whitespaces)
            let prefix = label.isEmpty ? "- " : "- \(label) "
            switch b.kind {
            case .steady: return prefix + "\(time(b.duration)) \(b.startPercent)%"
            case .ramp: return prefix + "\(time(b.duration)) ramp \(b.startPercent)-\(b.endPercent)%"
            case .free: return prefix + "\(time(b.duration)) freeride"
            case .repeats: return ""
            }
        }
        var parts: [String] = []
        for block in blocks {
            if block.kind == .repeats {
                parts.append((["\(Swift.max(1, block.reps))x"] + block.children.map(line)).joined(separator: "\n"))
            } else {
                parts.append(line(block))
            }
        }
        // intervals.icu needs blank lines around repeat groups.
        return parts.joined(separator: "\n\n")
    }

    /// Editable copy of an imported workout. Runs of identical step pairs become repeat groups.
    static func from(_ workout: Workout) -> CustomWorkout {
        func block(_ step: WorkoutStep) -> WorkoutBlock {
            let label = step.label ?? ""
            switch step.kind {
            case .free: return .free(step.duration / 60, label)
            case .ramp:
                return .ramp(step.duration / 60, percent(step.startFraction), percent(step.endFraction), label)
            case .steady:
                return .steady(step.duration / 60, percent(step.startFraction), label)
            }
        }
        func percent(_ f: Double?) -> Int { Int(((f ?? 0.5) * 100).rounded()) }

        let steps = workout.steps
        var blocks: [WorkoutBlock] = []
        var i = 0
        while i < steps.count {
            // Look for a pair (work, rest) that repeats at least twice.
            if i + 3 < steps.count, steps[i] == steps[i + 2], steps[i + 1] == steps[i + 3] {
                var reps = 2
                while i + reps * 2 + 1 < steps.count, steps[i + reps * 2] == steps[i], steps[i + reps * 2 + 1] == steps[i + 1] {
                    reps += 1
                }
                blocks.append(.repeats(reps, [block(steps[i]), block(steps[i + 1])]))
                i += reps * 2
            } else {
                blocks.append(block(steps[i]))
                i += 1
            }
        }
        return CustomWorkout(name: workout.name, notes: workout.description ?? "", blocks: blocks)
    }

    /// Starting points for new workouts.
    static var templates: [CustomWorkout] {
        [
            CustomWorkout(name: "Leeres Workout", blocks: [.ramp(10, 45, 70, "Aufwärmen"), .ramp(5, 65, 45, "Ausfahren")]),
            CustomWorkout(name: "Sweet Spot 3 × 10", blocks: [
                .ramp(10, 45, 70, "Aufwärmen"),
                .repeats(3, [.steady(10, 90, "Sweet Spot"), .steady(5, 55, "Erholung")]),
                .ramp(10, 65, 45, "Ausfahren"),
            ]),
            CustomWorkout(name: "VO2max 5 × 3", blocks: [
                .ramp(12, 45, 75, "Aufwärmen"),
                .repeats(5, [.steady(3, 115, "VO2max"), .steady(3, 50, "Erholung")]),
                .ramp(8, 60, 45, "Ausfahren"),
            ]),
            CustomWorkout(name: "Grundlage 60", blocks: [
                .ramp(8, 45, 65, "Aufwärmen"),
                .steady(45, 68, "Grundlage"),
                .ramp(7, 60, 45, "Ausfahren"),
            ]),
            CustomWorkout(name: "Schwelle 2 × 20", blocks: [
                .ramp(12, 45, 75, "Aufwärmen"),
                .repeats(2, [.steady(20, 97, "Schwelle"), .steady(8, 55, "Erholung")]),
                .ramp(8, 60, 45, "Ausfahren"),
            ]),
        ]
    }
}

/// Saves the workouts created in the app as one JSON file.
@Observable @MainActor
final class CustomWorkoutStore {
    private(set) var workouts: [CustomWorkout] = []
    @ObservationIgnored let fileURL: URL

    init(directory: URL? = nil) {
        let base = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BikeApp", isDirectory: true)
        fileURL = base.appendingPathComponent("Workouts.json")
        load()
    }

    func workout(id: String) -> CustomWorkout? {
        workouts.first { CustomWorkout.idPrefix + $0.id.uuidString == id }
    }

    func save(_ workout: CustomWorkout) {
        var w = workout
        w.modified = Date()
        if let i = workouts.firstIndex(where: { $0.id == w.id }) {
            workouts[i] = w
        } else {
            workouts.insert(w, at: 0)
        }
        persist()
    }

    func delete(_ id: UUID) {
        workouts.removeAll { $0.id == id }
        persist()
    }

    func duplicate(_ workout: CustomWorkout) -> CustomWorkout {
        var copy = workout
        copy.id = UUID()
        copy.name = workout.name + " (Kopie)"
        copy.blocks = workout.blocks.map { $0.copy() }
        save(copy)
        return copy
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        workouts = (try? decoder.decode([CustomWorkout].self, from: data)) ?? []
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(workouts).write(to: fileURL, options: .atomic)
        } catch {
            NSLog("BikeApp: Workouts konnten nicht gespeichert werden: \(error.localizedDescription)")
        }
    }
}
