import Foundation
import Observation

struct PowerPoint: Equatable {
    var time: TimeInterval
    var watts: Double
}

/// Runs a ride: reads sensors, integrates virtual speed and distance, drives the trainer, records data.
@Observable @MainActor
final class RideEngine {
    enum Phase: Equatable {
        /// Session created, waiting for the first pedal stroke.
        case waiting
        case riding
        case paused
        case finished
    }

    private(set) var config: SessionConfig
    let profile: ElevationProfile
    private(set) var player: WorkoutPlayer?
    /// FTP test progress (nil for normal rides).
    private(set) var testTracker: FTPTestTracker?
    private(set) var testResult: FTPTestResult?
    @ObservationIgnored var onTestResult: ((FTPTestResult) -> Void)?

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let ble: BLEManager
    @ObservationIgnored private let ftpProvider: () -> Int
    @ObservationIgnored let recorder = RideRecorder()
    @ObservationIgnored var onFinish: ((RideEngine) -> Void)?

    private(set) var phase: Phase = .waiting
    private(set) var manualPause = false
    private(set) var startDate = Date()
    private(set) var endDate: Date?
    private(set) var movingTime: TimeInterval = 0
    private(set) var distance: Double = 0
    /// Virtual speed in m/s.
    private(set) var speed: Double = 0
    private(set) var power3s: Int = 0
    private(set) var cadence: Int = 0
    private(set) var heartRate: Int?
    /// Smoothed course grade in percent.
    private(set) var gradePercent: Double = 0
    private(set) var gearbox: VirtualGearbox
    private(set) var ergOffset: Int = 0
    private(set) var shiftCount = 0
    private(set) var targetWatts: Int?
    private(set) var stepIndex: Int?
    private(set) var barColumns: [ProfileColumn] = []
    private(set) var barMarker: Double = 0
    private(set) var fullColumns: [ProfileColumn] = []
    private(set) var fullMarker: Double = 0
    private(set) var fullWindow: ClosedRange<Double> = 0...1
    private(set) var powerTrace: [PowerPoint] = []
    /// No trainer and no cadence data: the clock runs on its own, pause only by hand.
    private(set) var sensorless = false
    /// No trainer power: speed comes from cadence and the virtual gear.
    private(set) var speedFromCadence = false

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var lastTick: Date?
    @ObservationIgnored private var idleTime: TimeInterval = 0
    @ObservationIgnored private var powerWindow: [(time: Date, watts: Int)] = []
    @ObservationIgnored private var lastCommand: TrainerCommand?
    @ObservationIgnored private var lastCommandAt = Date.distantPast
    @ObservationIgnored private var nextSampleAt: TimeInterval = 1
    @ObservationIgnored private var lastSecondPower = 0
    @ObservationIgnored private var calibrator = TrainerRatioCalibrator()
    @ObservationIgnored private var traceAccumulator: (sum: Double, count: Int) = (0, 0)

    static let baseAltitude = 240.0

    init(config: SessionConfig, settings: AppSettings, ble: BLEManager, ftp: @escaping () -> Int) {
        self.config = config
        self.settings = settings
        self.ble = ble
        ftpProvider = ftp
        profile = ElevationProfile(range: config.gradeRange, seed: config.seed)
        player = config.workout.map(WorkoutPlayer.init(workout:))
        testTracker = config.test.map(FTPTestTracker.init(plan:))
        gearbox = VirtualGearbox(gear: settings.startGear)
        if case let .distance(meters) = config.goal { profile.ensure(distance: meters + 500) }
        refreshColumns()
    }

    var ftp: Int { ftpProvider() }

    // MARK: Lifecycle

    func start() {
        startDate = Date()
        lastTick = nil
        timer?.invalidate()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        updateWorkoutTarget()
        applyResistance(force: true)
    }

    func togglePause() {
        switch phase {
        case .riding, .waiting:
            phase = .paused
            manualPause = true
        case .paused:
            manualPause = false
            phase = .riding
            idleTime = 0
        case .finished:
            break
        }
    }

    func finish() {
        guard phase != .finished else { return }
        phase = .finished
        timer?.invalidate()
        timer = nil
        let now = Date()
        endDate = now
        // Ending the session during a test effort still evaluates it (an aborted 20 minutes is flagged).
        if var tracker = testTracker, !tracker.finished, movingTime >= (config.test?.effortStart ?? .infinity) {
            tracker.endManually()
            testTracker = tracker
            if let result = tracker.result {
                testResult = result
                onTestResult?(result)
            }
        }
        recorder.finish(at: now, elapsed: movingTime)
        if settings.measuredTrainerRatio <= 0, calibrator.isCalibrated, let ratio = calibrator.estimate {
            settings.measuredTrainerRatio = ratio
        }
        ble.send(.neutral)
        onFinish?(self)
    }

    func shift(_ direction: ShiftDirection) {
        guard phase != .finished else { return }
        if clickAdjustsErgOffset {
            ergOffset = Swift.min(150, Swift.max(-150, ergOffset + (direction == .up ? 5 : -5)))
            updateWorkoutTarget()
        } else {
            guard gearbox.shift(direction) else { return }
        }
        shiftCount += 1
        applyResistance(force: true)
    }

    // MARK: FTP test

    var isTest: Bool { config.test != nil }

    /// True during the evaluated part of a test.
    var isInTestEffort: Bool { testTracker?.isInEffort(at: movingTime) ?? false }

    /// The ramp can be ended by the rider ("I'm done"); the 20 minutes run to the end.
    var canEndTestEffort: Bool { config.test?.kind == .ramp && isInTestEffort }

    var testEstimate: Int? { testResult?.ftp ?? testTracker?.estimate }

    /// Ends the ramp now: evaluates it and continues with the cooldown.
    func endTestEffort() {
        guard var tracker = testTracker, !tracker.finished, movingTime >= (config.test?.effortStart ?? .infinity) else { return }
        tracker.endManually()
        testTracker = tracker
        testEffortEnded()
    }

    private func testEffortEnded() {
        guard let tracker = testTracker, let result = tracker.result, let plan = config.test else { return }
        testResult = result
        if plan.kind == .ramp, let workout = player?.workout, movingTime < plan.effortEnd {
            // Replace the rest of the ramp with the cooldown.
            let shortened = FTPTestPlan.truncated(workout, at: movingTime)
            config.workout = shortened
            player = WorkoutPlayer(workout: shortened)
            updateWorkoutTarget()
            applyResistance(force: true)
        }
        onTestResult?(result)
    }

    // MARK: Goal

    /// Free rides can change their goal while riding; workouts end with the workout.
    var canChangeGoal: Bool { player == nil && phase != .finished }

    /// Sets a new distance or duration goal. A goal already behind the rider is moved just ahead.
    func setGoal(_ goal: SessionGoal) {
        guard canChangeGoal else { return }
        switch goal {
        case let .distance(meters):
            let minimum = ((distance + 500) / 1000).rounded(.up) * 1000
            let target = Swift.max(meters, minimum)
            profile.ensure(distance: target + 500)
            config.goal = .distance(meters: target)
        case let .duration(seconds):
            let minimum = ((movingTime + 60) / 60).rounded(.up) * 60
            config.goal = .duration(seconds: Swift.max(seconds, minimum))
        case .workout:
            return
        }
        // The shown course changes with the goal.
        barColumns = []
        fullColumns = []
        refreshColumns()
    }

    /// Lengthens (+1) or shortens (−1) the goal by 5 km or 5 minutes.
    func adjustGoal(by steps: Int) {
        switch config.goal {
        case let .distance(meters):
            let next = ((meters / SessionGoal.distanceStep).rounded() + Double(steps)) * SessionGoal.distanceStep
            setGoal(.distance(meters: Swift.max(SessionGoal.distanceStep, next)))
        case let .duration(seconds):
            let next = ((seconds / SessionGoal.durationStep).rounded() + Double(steps)) * SessionGoal.durationStep
            setGoal(.duration(seconds: Swift.max(SessionGoal.durationStep, next)))
        case .workout:
            break
        }
    }

    // MARK: Derived state

    var isWorkout: Bool { player != nil }

    /// The trainer is in ERG mode right now (workout step with a target).
    var isErgActive: Bool {
        guard config.workoutMode.usesERG, let player, let step = player.position(at: movingTime)?.step else { return false }
        return step.hasTarget
    }

    var clickAdjustsErgOffset: Bool { config.workoutMode == .ergOffset && isErgActive }

    var workoutPosition: WorkoutPlayer.Position? { player?.position(at: movingTime) }

    var remainingDistance: Double? {
        if case let .distance(meters) = config.goal { return Swift.max(0, meters - distance) }
        return nil
    }

    var remainingTime: TimeInterval? {
        switch config.goal {
        case let .duration(seconds): return Swift.max(0, seconds - movingTime)
        case .workout: return Swift.max(0, (player?.duration ?? 0) - movingTime)
        case .distance: return nil
        }
    }

    /// 0…1 progress towards the goal.
    var progress: Double {
        switch config.goal {
        case let .distance(meters): return meters > 0 ? Swift.min(1, distance / meters) : 0
        case let .duration(seconds): return seconds > 0 ? Swift.min(1, movingTime / seconds) : 0
        case .workout:
            let total = player?.duration ?? 0
            return total > 0 ? Swift.min(1, movingTime / total) : 0
        }
    }

    var altitude: Double { Self.baseAltitude + profile.elevation(at: distance) }

    var ascent: Double { config.usesCourse ? profile.ascent(upTo: distance) : 0 }

    var nextKilometerGrade: Double { profile.averageGrade(from: distance, length: 1000) }

    // MARK: Tick

    private func tick() {
        let now = Date()
        let dt = lastTick.map { Swift.min(1, Swift.max(0, now.timeIntervalSince($0))) } ?? 0.25
        lastTick = now
        let live = ble.live
        let rawPower = live.power(at: now) ?? 0
        let rawCadence = live.cadence(at: now) ?? 0
        heartRate = live.heartRate(at: now)
        cadence = Int(rawCadence.rounded())
        updatePowerAverage(rawPower, now: now)
        if let trainerSpeed = live.trainerSpeed(at: now), let trainerCadence = live.trainerCadence {
            calibrator.add(trainerSpeed: trainerSpeed, cadence: trainerCadence, wheelCircumference: settings.rider.wheelCircumference)
        }

        // Without trainer and cadence sensor the ride is a plain timer (after a short grace period at the start).
        sensorless = !ble.hasMotionData(at: now) && now.timeIntervalSince(startDate) > 5
        speedFromCadence = live.power(at: now) == nil && rawCadence > 0
        let pedaling = sensorless || rawPower > 15 || rawCadence > 20
        switch phase {
        case .waiting:
            if pedaling {
                phase = .riding
                idleTime = 0
            }
        case .riding:
            idleTime = pedaling ? 0 : idleTime + dt
            if canEndTestEffort, idleTime >= 2 {
                // Stopping during the ramp means "done", not "pause".
                endTestEffort()
            } else if idleTime >= 3 {
                phase = .paused
            }
        case .paused:
            if !manualPause, pedaling {
                phase = .riding
                idleTime = 0
            }
        case .finished:
            return
        }

        let rider = settings.rider
        if phase == .riding {
            movingTime += dt
            let physicsGrade = config.usesCourse ? gradePercent : 0
            if speedFromCadence {
                // No power from a trainer: roll as fast as the virtual gear and the cadence say.
                let target = rawCadence / 60 * gearbox.ratio * rider.wheelCircumference
                speed += (target - speed) * Swift.min(1, dt * 2)
            } else {
                speed = BikePhysics.advance(speed: speed, power: Double(rawPower), gradePercent: physicsGrade, dt: dt, rider: rider)
            }
            distance += speed * dt
        } else {
            speed = 0
        }

        // Course grade, limited to 0.5 %/s so the trainer does not jerk.
        if config.usesCourse {
            let raw = profile.grade(at: distance)
            let maxStep = 0.5 * dt
            gradePercent += Swift.min(maxStep, Swift.max(-maxStep, raw - gradePercent))
        } else {
            gradePercent = 0
        }

        updateWorkoutTarget()
        applyResistance()

        if phase == .riding, movingTime >= nextSampleAt {
            nextSampleAt += 1
            recordSample(now: now, power: rawPower)
            refreshColumns()
        }
        checkGoal()
    }

    private func updatePowerAverage(_ watts: Int, now: Date) {
        powerWindow.append((now, watts))
        powerWindow.removeAll { now.timeIntervalSince($0.time) > 3 }
        let sum = powerWindow.reduce(0) { $0 + $1.watts }
        power3s = powerWindow.isEmpty ? 0 : Int((Double(sum) / Double(powerWindow.count)).rounded())
    }

    private func updateWorkoutTarget() {
        guard let player else {
            targetWatts = nil
            stepIndex = nil
            return
        }
        let position = player.position(at: movingTime)
        if let index = position?.index, index != stepIndex {
            if stepIndex != nil { recorder.markLap(at: Date(), elapsed: movingTime) }
            stepIndex = index
        }
        if let fraction = player.targetFraction(at: movingTime) {
            let offset = config.workoutMode == .ergOffset ? ergOffset : 0
            targetWatts = Swift.max(0, Int((fraction * Double(ftp)).rounded()) + offset)
        } else {
            targetWatts = nil
        }
    }

    /// Sends the current resistance again, e.g. after the trainer reconnected.
    func resendResistance() {
        guard phase != .finished else { return }
        applyResistance(force: true)
    }

    private func applyResistance(force: Bool = false) {
        let command: TrainerCommand
        if isErgActive, let target = targetWatts {
            command = .targetPower(watts: target)
        } else {
            let input = ResistanceInput(
                gradePercent: gradePercent,
                difficulty: settings.difficulty,
                virtualRatio: gearbox.ratio,
                trainerRatio: calibrator.isCalibrated ? (calibrator.estimate ?? settings.trainerRatio) : settings.trainerRatio,
                cadence: Double(cadence),
                rider: settings.rider
            )
            // Trainers without slope simulation get the gears as ERG targets.
            let mode = ble.trainerSupportsSimulation ? settings.resistanceMode : .ergVirtual
            switch mode {
            case .matchedSimulation: command = MatchedSimulationStrategy().command(for: input)
            case .ergVirtual: command = ErgVirtualStrategy().command(for: input)
            }
        }
        let now = Date()
        let changed = lastCommand.map { !command.isClose(to: $0) } ?? true
        let keepAlive = now.timeIntervalSince(lastCommandAt) > 5
        guard force || changed || keepAlive else { return }
        guard force || now.timeIntervalSince(lastCommandAt) >= 0.24 else { return }
        ble.send(command)
        lastCommand = command
        lastCommandAt = now
    }

    private func recordSample(now: Date, power: Int) {
        recorder.add(RideSample(
            timestamp: now,
            elapsed: movingTime,
            power: power,
            cadence: cadence > 0 ? cadence : nil,
            heartRate: heartRate,
            speed: speed,
            distance: distance,
            altitude: altitude,
            gradePercent: config.usesCourse ? gradePercent : 0
        ))
        traceAccumulator.sum += Double(power)
        traceAccumulator.count += 1
        if traceAccumulator.count >= 5 {
            powerTrace.append(PowerPoint(time: movingTime, watts: traceAccumulator.sum / Double(traceAccumulator.count)))
            traceAccumulator = (0, 0)
        }
        if var tracker = testTracker, !tracker.finished {
            let ended = tracker.add(time: movingTime, power: power, cadence: cadence, target: targetWatts)
            testTracker = tracker
            if ended { testEffortEnded() }
        }
    }

    private func checkGoal() {
        switch config.goal {
        case let .distance(meters):
            if distance >= meters { finish() }
        case let .duration(seconds):
            if movingTime >= seconds { finish() }
        case .workout:
            if let player, movingTime >= player.duration { finish() }
        }
    }

    /// Profile columns for the bar (110) and the full screen view (262).
    private func refreshColumns() {
        guard config.usesCourse else {
            barColumns = []
            fullColumns = []
            return
        }
        if case let .distance(meters) = config.goal {
            // The whole course is known in advance, so the columns never change.
            if barColumns.isEmpty { barColumns = profile.columns(from: 0, to: meters, count: 110) }
            barMarker = meters > 0 ? Swift.min(1, distance / meters) : 0
            if fullColumns.isEmpty { fullColumns = profile.columns(from: 0, to: meters, count: 262) }
            fullMarker = barMarker
            fullWindow = 0...meters
        } else {
            barColumns = profile.columns(from: distance - 1000, to: distance + 4000, count: 110)
            barMarker = 0.2
            fullColumns = profile.columns(from: distance - 2000, to: distance + 8000, count: 262)
            fullMarker = 0.2
            fullWindow = (distance - 2000)...(distance + 8000)
        }
    }

    // MARK: Previews and snapshots

    /// Puts the engine into a fixed state without sensors (used for previews and tests).
    func applyPreview(distance: Double, movingTime: TimeInterval, power: Int, cadence: Int, heartRate: Int?, gear: Int, phase: Phase = .riding) {
        self.distance = distance
        self.movingTime = movingTime
        self.power3s = power
        self.cadence = cadence
        self.heartRate = heartRate
        self.phase = phase
        gearbox = VirtualGearbox(gear: gear)
        gradePercent = config.usesCourse ? profile.grade(at: distance) : 0
        speed = phase == .riding ? BikePhysics.steadySpeed(power: Double(power), gradePercent: gradePercent, rider: settings.rider) : 0
        if let player {
            var trace: [PowerPoint] = []
            var t: TimeInterval = 0
            var rng = SplitMix64(seed: 7)
            var last = (player.targetFraction(at: 0) ?? 0.5) * Double(ftp)
            while t < movingTime {
                let target = (player.targetFraction(at: t) ?? 0.5) * Double(ftp)
                last += (target - last) * 0.5 + (rng.unit() - 0.5) * 0.07 * target
                trace.append(PowerPoint(time: t, watts: last))
                t += 5
            }
            powerTrace = trace
        }
        if let plan = config.test, var tracker = testTracker {
            // Feed the test as if the rider had held every target.
            var t = plan.effortStart
            while t < movingTime, !tracker.finished {
                let target = player?.targetFraction(at: t).map { Int(($0 * Double(ftp)).rounded()) } ?? Int(Double(plan.baseFTP) * 1.02)
                _ = tracker.add(time: t, power: target, cadence: cadence, target: target)
                t += 1
            }
            testTracker = tracker
        }
        updateWorkoutTarget()
        refreshColumns()
    }
}
