import Foundation

enum ShiftDirection: Equatable {
    case up
    case down
}

/// 24 virtual gears, similar in range to Zwift's virtual shifting.
struct VirtualGearbox: Equatable {
    static let ratios: [Double] = [
        0.75, 0.87, 0.99, 1.11, 1.23, 1.38, 1.53, 1.68,
        1.86, 2.04, 2.22, 2.40, 2.61, 2.82, 3.03, 3.24,
        3.49, 3.74, 3.98, 4.23, 4.54, 4.85, 5.16, 5.49,
    ]

    static var count: Int { ratios.count }

    private(set) var gear: Int

    init(gear: Int = 12) {
        self.gear = Swift.min(Self.count, Swift.max(1, gear))
    }

    var ratio: Double { Self.ratios[gear - 1] }

    /// Shifts one gear. "up" means harder. Returns false at the end of the range.
    @discardableResult
    mutating func shift(_ direction: ShiftDirection) -> Bool {
        switch direction {
        case .up:
            guard gear < Self.count else { return false }
            gear += 1
        case .down:
            guard gear > 1 else { return false }
            gear -= 1
        }
        return true
    }
}
