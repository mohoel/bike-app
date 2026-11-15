import Foundation

/// Power zones as upper bounds in percent of FTP (defaults match intervals.icu).
struct PowerZones: Equatable {
    static let standard = PowerZones(upperBounds: [55, 75, 90, 105, 120])

    /// Upper bounds of Z1…Z5 in percent of FTP. Everything above is Z6 (Z6 and Z7 share a colour).
    var upperBounds: [Double]

    static let names = ["Erholung", "Grundlage", "Tempo", "Schwelle", "VO2max", "Anaerob"]

    /// Zone index 0…5 for a fraction of FTP.
    func index(forFraction fraction: Double) -> Int {
        let percent = fraction * 100
        for (i, bound) in upperBounds.enumerated() where percent < bound + 0.5 {
            return i
        }
        return Swift.min(5, upperBounds.count)
    }

    func index(watts: Double, ftp: Double) -> Int {
        guard ftp > 0 else { return 0 }
        return index(forFraction: watts / ftp)
    }

    static func shortName(_ index: Int) -> String { "Z\(index + 1)" }
    static func name(_ index: Int) -> String { names[Swift.min(names.count - 1, Swift.max(0, index))] }
}

/// How well the current power matches a workout target.
enum TargetCompliance: Equatable {
    case inTarget
    case tooLow
    case tooHigh

    init(watts: Double, target: Double, tolerance: Double = 0.05) {
        guard target > 0 else { self = .inTarget; return }
        let ratio = watts / target
        if abs(ratio - 1) <= tolerance {
            self = .inTarget
        } else if ratio < 1 {
            self = .tooLow
        } else {
            self = .tooHigh
        }
    }

    var label: String {
        switch self {
        case .inTarget: return "IM ZIEL"
        case .tooLow: return "ZU NIEDRIG"
        case .tooHigh: return "ZU HOCH"
        }
    }
}
