import Foundation

struct RiderParameters: Equatable {
    var riderMass: Double = 75
    var bikeMass: Double = 8
    var crr: Double = 0.004
    var cda: Double = 0.32
    var airDensity: Double = 1.2
    var drivetrainEfficiency: Double = 0.98
    var wheelCircumference: Double = 2.096

    var totalMass: Double { riderMass + bikeMass }
}

/// Road cycling physics used for the virtual speed and for trainer resistance.
enum BikePhysics {
    static let gravity = 9.81
    /// Extra mass that models the rotating wheels.
    static let wheelInertiaMass = 1.5

    /// Rolling, gravity and air resistance in newtons (negative when rolling downhill).
    static func resistiveForce(speed: Double, gradePercent: Double, rider: RiderParameters) -> Double {
        let theta = atan(gradePercent / 100)
        let slope = rider.totalMass * gravity * (rider.crr * cos(theta) + sin(theta))
        let air = 0.5 * rider.airDensity * rider.cda * speed * speed
        return slope + air
    }

    /// Power at the pedals needed to hold a speed.
    static func powerRequired(speed: Double, gradePercent: Double, rider: RiderParameters) -> Double {
        let p = resistiveForce(speed: speed, gradePercent: gradePercent, rider: rider) * speed
        return Swift.max(0, p) / rider.drivetrainEfficiency
    }

    /// Speed in m/s that a constant power holds on a constant grade.
    static func steadySpeed(power: Double, gradePercent: Double, rider: RiderParameters) -> Double {
        let wheelPower = Swift.max(0, power) * rider.drivetrainEfficiency
        func f(_ v: Double) -> Double {
            resistiveForce(speed: v, gradePercent: gradePercent, rider: rider) * v - wheelPower
        }
        var lo = 1e-4
        var hi = 60.0
        if f(lo) >= 0 { return 0 }
        for _ in 0..<60 {
            let mid = (lo + hi) / 2
            if f(mid) > 0 { hi = mid } else { lo = mid }
        }
        return lo
    }

    /// Integrates the speed over `dt` seconds using the energy balance.
    static func advance(speed: Double, power: Double, gradePercent: Double, dt: Double, rider: RiderParameters) -> Double {
        let mass = rider.totalMass + wheelInertiaMass
        let force = resistiveForce(speed: speed, gradePercent: gradePercent, rider: rider)
        let energy = 0.5 * mass * speed * speed + (Swift.max(0, power) * rider.drivetrainEfficiency - force * speed) * dt
        return sqrt(Swift.max(0, 2 * energy / mass))
    }
}
