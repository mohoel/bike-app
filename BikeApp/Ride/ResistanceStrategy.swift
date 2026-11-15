import Foundation

enum TrainerCommand: Equatable {
    /// FTMS indoor bike simulation: grade in percent, rolling resistance coefficient, wind resistance in kg/m.
    case simulation(gradePercent: Double, crr: Double, windResistance: Double)
    /// FTMS ERG target power.
    case targetPower(watts: Int)

    static let neutral = TrainerCommand.simulation(gradePercent: 0, crr: 0.004, windResistance: 0.38)

    func isClose(to other: TrainerCommand) -> Bool {
        switch (self, other) {
        case let (.simulation(g1, c1, w1), .simulation(g2, c2, w2)):
            return abs(g1 - g2) < 0.1 && abs(c1 - c2) < 0.0002 && abs(w1 - w2) < 0.01
        case let (.targetPower(a), .targetPower(b)):
            return abs(a - b) < 2
        default:
            return false
        }
    }
}

struct ResistanceInput: Equatable {
    var gradePercent: Double
    var difficulty: Double
    var virtualRatio: Double
    var trainerRatio: Double
    var cadence: Double
    var rider: RiderParameters
}

protocol ResistanceStrategy {
    func command(for input: ResistanceInput) -> TrainerCommand
}

/// Makes the trainer's own physics behave like the virtual gear.
///
/// With the Zwift Cog the trainer always spins in the same real gear. A harder virtual
/// gear means the virtual bike rolls k times faster than the trainer thinks it does,
/// where k = virtual ratio / real ratio. The trainer computes its resistance as
///   P = (m·g·(crr + sin θ) + ½·cw·v²)·v
/// from its own speed v. Scaling crr and the slope by k and the wind coefficient by k³
/// gives exactly the power the virtual bike would need at speed k·v, so shifting and
/// climbing feel right without waiting for the app.
struct MatchedSimulationStrategy: ResistanceStrategy {
    static let gradeLimits: ClosedRange<Double> = -15...20

    func command(for input: ResistanceInput) -> TrainerCommand {
        let k = Swift.min(3.0, Swift.max(0.2, input.virtualRatio / Swift.max(0.1, input.trainerRatio)))
        let effectiveGrade = input.gradePercent * input.difficulty
        let sinTheta = sin(atan(effectiveGrade / 100))
        let crr = Swift.min(0.0254, Swift.max(0, k * input.rider.crr))
        let linear = k * (input.rider.crr + sinTheta)
        let sinTrainer = Swift.min(0.35, Swift.max(-0.35, linear - crr))
        var grade = tan(asin(sinTrainer)) * 100
        grade = Swift.min(Self.gradeLimits.upperBound, Swift.max(Self.gradeLimits.lowerBound, grade))
        let wind = Swift.min(2.54, input.rider.airDensity * input.rider.cda * k * k * k)
        return .simulation(gradePercent: grade, crr: crr, windResistance: wind)
    }
}

/// Computes the power the virtual bike needs at the current cadence and gear and sets it in ERG mode.
struct ErgVirtualStrategy: ResistanceStrategy {
    func command(for input: ResistanceInput) -> TrainerCommand {
        let speed = input.cadence / 60 * input.virtualRatio * input.rider.wheelCircumference
        let grade = input.gradePercent * input.difficulty
        let watts = BikePhysics.powerRequired(speed: speed, gradePercent: grade, rider: input.rider)
        return .targetPower(watts: Int(Swift.min(1200, Swift.max(0, watts)).rounded()))
    }
}

/// Learns the real gear ratio from trainer speed and cadence while riding steadily.
struct TrainerRatioCalibrator {
    private(set) var estimate: Double?
    private(set) var samples = 0

    var isCalibrated: Bool { samples >= 40 }

    mutating func add(trainerSpeed: Double, cadence: Double, wheelCircumference: Double) {
        guard cadence > 55, cadence < 130, trainerSpeed > 2 else { return }
        let ratio = trainerSpeed * 60 / (cadence * wheelCircumference)
        guard ratio > 0.8, ratio < 6 else { return }
        if let current = estimate {
            estimate = current + (ratio - current) * 0.05
        } else {
            estimate = ratio
        }
        samples += 1
    }
}
