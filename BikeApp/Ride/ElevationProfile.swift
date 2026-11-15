import Foundation

struct GradeRange: Equatable, Codable {
    var min: Double
    var max: Double
}

enum CoursePreset: String, CaseIterable, Identifiable {
    case flat
    case rolling
    case hilly
    case mountainous
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .flat: return "Flach"
        case .rolling: return "Wellig"
        case .hilly: return "Hügelig"
        case .mountainous: return "Bergig"
        case .custom: return "Eigene"
        }
    }

    var range: GradeRange? {
        switch self {
        case .flat: return GradeRange(min: 0, max: 2)
        case .rolling: return GradeRange(min: -3, max: 4)
        case .hilly: return GradeRange(min: -5, max: 7)
        case .mountainous: return GradeRange(min: -6, max: 10)
        case .custom: return nil
        }
    }
}

/// Small, fast, deterministic random number generator (SplitMix64).
struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform value in [0, 1).
    mutating func unit() -> Double {
        Double(next() >> 11) / Double(UInt64(1) << 53)
    }
}

struct ProfileColumn: Equatable {
    /// Height within the shown window, 0 = lowest point, 1 = highest point.
    var norm: Double
    /// Average grade of the column in percent.
    var grade: Double
}

/// Procedurally generated course: a function from distance to grade and elevation.
///
/// The course is made of segments of 200–1500 m with a random target grade inside
/// the chosen range. Grades blend smoothly between segments. For ranges with climbs
/// and descents, the generator leans towards descending when the course is high and
/// towards climbing when it is low, so a long ride does not only go uphill.
/// New samples are generated on demand, so rides by duration have no fixed length.
final class ElevationProfile {
    static let spacing: Double = 50

    let range: GradeRange
    let seed: UInt64

    private var rng: SplitMix64
    private(set) var grades: [Double] = []
    private(set) var endElevations: [Double] = []
    private var target = 0.0
    private var remaining = 0.0
    private var current = 0.0
    private var height = 0.0
    private let bandCenter: Double
    private let bandScale: Double

    init(range: GradeRange, seed: UInt64) {
        self.range = GradeRange(min: Swift.min(range.min, range.max), max: Swift.max(range.min, range.max))
        self.seed = seed
        rng = SplitMix64(seed: seed)
        let span = Swift.max(1, self.range.max - self.range.min)
        bandCenter = 120 * span / 16
        bandScale = 400 * span / 16
        current = Swift.min(Swift.max(0, self.range.min), self.range.max)
    }

    /// Makes sure samples exist up to `distance` metres.
    func ensure(distance: Double) {
        let needed = Int((Swift.max(0, distance) / Self.spacing).rounded(.up)) + 1
        while grades.count < needed { generateSample() }
    }

    private func generateSample() {
        if remaining <= 0 {
            target = nextTarget()
            remaining = 200 + rng.unit() * 1300
        }
        remaining -= Self.spacing
        current += (target - current) * 0.15
        current = Swift.min(range.max, Swift.max(range.min, current))
        grades.append(current)
        height += current / 100 * Self.spacing
        endElevations.append(height)
    }

    private func nextTarget() -> Double {
        if range.min >= 0 || range.max <= 0 {
            return range.min + rng.unit() * (range.max - range.min)
        }
        let pUp = Swift.min(0.8, Swift.max(0.2, 0.55 - (height - bandCenter) / bandScale))
        if rng.unit() < pUp {
            return rng.unit() * range.max
        }
        return rng.unit() * range.min
    }

    private func index(for distance: Double) -> Int {
        let d = Swift.max(0, distance)
        ensure(distance: d + Self.spacing)
        return Swift.min(grades.count - 1, Int(d / Self.spacing))
    }

    /// Grade in percent at a distance in metres.
    func grade(at distance: Double) -> Double {
        grades[index(for: distance)]
    }

    /// Elevation in metres relative to the start.
    func elevation(at distance: Double) -> Double {
        let d = Swift.max(0, distance)
        let i = index(for: d)
        let start = i == 0 ? 0 : endElevations[i - 1]
        return start + grades[i] / 100 * (d - Double(i) * Self.spacing)
    }

    /// Climbing in metres from the start up to `distance`.
    func ascent(upTo distance: Double) -> Double {
        let d = Swift.max(0, distance)
        let last = index(for: d)
        var sum = 0.0
        for i in 0...last {
            let segment = i == last ? d - Double(i) * Self.spacing : Self.spacing
            if grades[i] > 0 { sum += grades[i] / 100 * segment }
        }
        return sum
    }

    /// Average grade in percent over `length` metres starting at `distance`.
    func averageGrade(from distance: Double, length: Double) -> Double {
        guard length > 0 else { return grade(at: distance) }
        return (elevation(at: distance + length) - elevation(at: distance)) / length * 100
    }

    /// Columns for a bar-style profile between two distances.
    func columns(from start: Double, to end: Double, count: Int, minimumSpan: Double = 30) -> [ProfileColumn] {
        guard count > 0, end > start else { return [] }
        ensure(distance: end + Self.spacing)
        let width = (end - start) / Double(count)
        var raw: [(elevation: Double, grade: Double)] = []
        raw.reserveCapacity(count)
        for k in 0..<count {
            let a = start + Double(k) * width
            let b = a + width
            let mid = (a + b) / 2
            let lo = Swift.max(0, a), hi = Swift.max(0, b)
            let g = hi > lo ? (elevation(at: hi) - elevation(at: lo)) / (hi - lo) * 100 : 0
            raw.append((elevation(at: Swift.max(0, mid)), g))
        }
        let lo = raw.map(\.elevation).min() ?? 0
        let hi = raw.map(\.elevation).max() ?? 0
        let span = Swift.max(hi - lo, minimumSpan)
        return raw.map { ProfileColumn(norm: ($0.elevation - lo) / span, grade: $0.grade) }
    }
}
