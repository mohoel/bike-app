import Foundation

/// Simulated trainer, heart rate and cadence for trying the app without hardware.
///
/// The simulated rider aims for a slowly changing effort and adapts cadence to the
/// resistance, so harder gears lower the cadence and climbs feel heavier.
@MainActor
final class DemoTrainer: TrainerDevice {
    private weak var manager: BLEManager?
    private let settings: AppSettings
    private var timer: Timer?
    private var mode: TrainerCommand = .neutral
    private var t: Double = 0
    private var cadence: Double = 85
    private var power: Double = 0
    private var heartRate: Double = 92
    private var rng = SplitMix64(seed: 42)

    var isReady: Bool { true }

    init(manager: BLEManager, settings: AppSettings) {
        self.manager = manager
        self.settings = settings
    }

    func start() {
        timer?.invalidate()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.step(dt: 0.25) }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func send(_ command: TrainerCommand) {
        mode = command
    }

    private func noise(_ amount: Double) -> Double {
        (rng.unit() - 0.5) * 2 * amount
    }

    private func step(dt: Double) {
        t += dt
        let ratio = settings.trainerRatio
        let circumference = 2.096
        let mass = settings.riderWeight + settings.bikeWeight
        let effort = 215 + 35 * sin(t / 47) + 20 * sin(t / 13)

        switch mode {
        case let .targetPower(watts):
            power += (Double(watts) - power) * 0.3 + noise(4)
            cadence += (88 - cadence) * 0.1 + noise(0.6)
        case let .simulation(grade, crr, wind):
            func powerAt(_ rpm: Double) -> Double {
                let v = rpm / 60 * ratio * circumference
                let theta = atan(grade / 100)
                return (mass * 9.81 * (crr * cos(theta) + sin(theta)) + 0.5 * wind * v * v) * v
            }
            var lo = 40.0, hi = 125.0
            var target: Double
            if powerAt(hi) < effort {
                target = 110
            } else if powerAt(lo) > effort {
                target = 55
            } else {
                for _ in 0..<30 {
                    let mid = (lo + hi) / 2
                    if powerAt(mid) < effort { lo = mid } else { hi = mid }
                }
                target = Swift.min(110, Swift.max(55, lo))
            }
            cadence += (target - cadence) * 0.25 + noise(0.5)
            power = Swift.max(0, powerAt(cadence)) + noise(5)
        }

        heartRate += ((92 + 0.3 * power) - heartRate) * 0.02
        let speed = cadence / 60 * ratio * circumference
        manager?.updateTrainer(IndoorBikeData(speedKmh: speed * 3.6, cadence: cadence, power: Int(power.rounded())))
        manager?.updateHeartRate(Int(heartRate.rounded()))
        manager?.updatePedalCadence(cadence)
    }
}
