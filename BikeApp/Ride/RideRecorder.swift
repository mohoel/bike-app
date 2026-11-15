import Foundation

struct RideSample: Equatable {
    var timestamp: Date
    var elapsed: TimeInterval
    var power: Int
    var cadence: Int?
    var heartRate: Int?
    /// m/s
    var speed: Double
    /// metres
    var distance: Double
    /// metres above sea level
    var altitude: Double
    var gradePercent: Double
}

struct RideLap: Equatable {
    var startTime: Date
    var endTime: Date
    var startElapsed: TimeInterval
    var endElapsed: TimeInterval
    var sampleRange: Range<Int>
}

struct RideSummary: Equatable {
    var startTime: Date
    var endTime: Date
    var movingTime: TimeInterval
    var elapsedTime: TimeInterval
    var distance: Double
    var avgPower: Int
    var maxPower: Int
    var normalizedPower: Int
    var avgCadence: Int?
    var maxCadence: Int?
    var avgHeartRate: Int?
    var maxHeartRate: Int?
    var avgSpeed: Double
    var maxSpeed: Double
    var ascent: Double
    var kilojoules: Double

    static func compute(samples: ArraySlice<RideSample>, startTime: Date, endTime: Date) -> RideSummary {
        let powers = samples.map(\.power)
        let cadences = samples.compactMap(\.cadence).filter { $0 > 0 }
        let hrs = samples.compactMap(\.heartRate).filter { $0 > 0 }
        let moving = (samples.last?.elapsed ?? 0) - (samples.first?.elapsed ?? 0) + (samples.isEmpty ? 0 : 1)
        let distance = Swift.max(0, (samples.last?.distance ?? 0) - (samples.first.map { $0.distance - $0.speed } ?? 0))
        var ascent = 0.0
        var previous: Double?
        for s in samples {
            if let p = previous, s.altitude > p { ascent += s.altitude - p }
            previous = s.altitude
        }
        return RideSummary(
            startTime: startTime,
            endTime: endTime,
            movingTime: moving,
            elapsedTime: endTime.timeIntervalSince(startTime),
            distance: distance,
            avgPower: powers.isEmpty ? 0 : Int((Double(powers.reduce(0, +)) / Double(powers.count)).rounded()),
            maxPower: powers.max() ?? 0,
            normalizedPower: normalizedPower(powers),
            avgCadence: cadences.isEmpty ? nil : Int((Double(cadences.reduce(0, +)) / Double(cadences.count)).rounded()),
            maxCadence: cadences.max(),
            avgHeartRate: hrs.isEmpty ? nil : Int((Double(hrs.reduce(0, +)) / Double(hrs.count)).rounded()),
            maxHeartRate: hrs.max(),
            avgSpeed: moving > 0 ? distance / moving : 0,
            maxSpeed: samples.map(\.speed).max() ?? 0,
            ascent: ascent,
            kilojoules: Double(powers.reduce(0, +)) / 1000
        )
    }

    /// Normalized power: 30 s rolling average, raised to the 4th power, averaged, 4th root.
    static func normalizedPower(_ powers: [Int]) -> Int {
        guard !powers.isEmpty else { return 0 }
        guard powers.count >= 30 else {
            return Int((Double(powers.reduce(0, +)) / Double(powers.count)).rounded())
        }
        var window = powers.prefix(30).reduce(0, +)
        var sum4 = 0.0
        var count = 0
        for i in 29..<powers.count {
            if i > 29 { window += powers[i] - powers[i - 30] }
            let avg = Double(window) / 30
            sum4 += pow(avg, 4)
            count += 1
        }
        return Int(pow(sum4 / Double(count), 0.25).rounded())
    }
}

/// Collects 1 Hz samples and laps of a ride.
final class RideRecorder {
    private(set) var samples: [RideSample] = []
    private(set) var laps: [RideLap] = []
    private var lapStart: (time: Date, elapsed: TimeInterval, index: Int)?

    func add(_ sample: RideSample) {
        if lapStart == nil {
            lapStart = (sample.timestamp, sample.elapsed, samples.count)
        }
        samples.append(sample)
    }

    /// Closes the current lap and starts a new one.
    func markLap(at time: Date, elapsed: TimeInterval) {
        guard let start = lapStart, samples.count > start.index else { return }
        laps.append(RideLap(startTime: start.time, endTime: time, startElapsed: start.elapsed, endElapsed: elapsed, sampleRange: start.index..<samples.count))
        lapStart = (time, elapsed, samples.count)
    }

    func finish(at time: Date, elapsed: TimeInterval) {
        markLap(at: time, elapsed: elapsed)
        lapStart = nil
    }
}
