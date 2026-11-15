import XCTest
@testable import BikeApp

final class IntervalsAndFITTests: XCTestCase {
    // MARK: intervals.icu parsing

    private let eventsJSON = """
    [
      {
        "id": 151050200,
        "start_date_local": "2026-11-13T00:00:00",
        "category": "WORKOUT",
        "type": "VirtualRide",
        "name": "Sweet Spot 3 × 10",
        "workout_doc": {
          "ftp": 250,
          "steps": [
            { "warmup": true, "duration": 600, "ramp": true, "power": { "units": "%ftp", "start": 50, "end": 75 } },
            { "reps": 3, "text": "Sweet Spot", "steps": [
                { "duration": 600, "power": { "units": "%ftp", "value": 92 } },
                { "duration": 300, "power": { "units": "%ftp", "value": 56 } }
            ] },
            { "duration": 120, "power": { "units": "w", "value": 300 } },
            { "duration": 180, "power": { "units": "power_zone", "value": 2 } },
            { "duration": 240, "power": { "units": "%ftp", "start": 88, "end": 94 } },
            { "duration": 300, "freeride": true },
            { "cooldown": true, "duration": 600, "ramp": true, "power": { "units": "%ftp", "start": 65, "end": 45 } }
          ]
        }
      },
      {
        "id": 151050201,
        "start_date_local": "2026-11-14T00:00:00",
        "category": "WORKOUT",
        "type": "Run",
        "name": "Lauf",
        "workout_doc": { "steps": [ { "duration": 600 } ] }
      },
      {
        "id": 151050202,
        "category": "WORKOUT",
        "type": "Ride",
        "name": "Ohne Struktur"
      }
    ]
    """

    func testParsesRideEventsAndFiltersOthers() throws {
        let workouts = try IntervalsWorkoutParser.parseEvents(Data(eventsJSON.utf8), fallbackFTP: 250)
        XCTAssertEqual(workouts.count, 1)
        let w = try XCTUnwrap(workouts.first)
        XCTAssertEqual(w.name, "Sweet Spot 3 × 10")
        XCTAssertEqual(w.eventId, 151050200)
        XCTAssertNotNil(w.date)
        // 1 warmup + 3 × 2 + watts + zone + range + free + cooldown = 12
        XCTAssertEqual(w.steps.count, 12)
        XCTAssertEqual(w.steps[0].kind, .ramp)
        XCTAssertEqual(w.steps[0].startFraction ?? 0, 0.5, accuracy: 1e-9)
        XCTAssertEqual(w.steps[0].endFraction ?? 0, 0.75, accuracy: 1e-9)
        XCTAssertEqual(w.steps[1].startFraction ?? 0, 0.92, accuracy: 1e-9)
        XCTAssertEqual(w.steps[1].label, nil)
        XCTAssertEqual(w.steps[6].startFraction ?? 0, 0.56, accuracy: 1e-9)
        XCTAssertEqual(w.steps[7].startFraction ?? 0, 1.2, accuracy: 1e-9) // 300 W of 250
        XCTAssertEqual(w.steps[8].startFraction ?? 0, 0.65, accuracy: 1e-9) // zone 2 midpoint
        XCTAssertEqual(w.steps[9].kind, .steady)
        XCTAssertEqual(w.steps[9].startFraction ?? 0, 0.91, accuracy: 1e-9) // range midpoint
        XCTAssertEqual(w.steps[10].kind, .free)
        XCTAssertEqual(w.steps[11].kind, .ramp)
        let expected: TimeInterval = 600 + 2700 + 120 + 180 + 240 + 300 + 600
        XCTAssertEqual(w.duration, expected)
    }

    func testParsesAthlete() throws {
        let json = """
        { "id": "i1", "name": "Test", "icu_weight": 72.5,
          "sportSettings": [
            { "types": ["Run"], "ftp": 276 },
            { "types": ["Ride", "VirtualRide"], "ftp": 250, "power_zones": [55, 75, 90, 105, 120, 150, 999] }
          ] }
        """
        let athlete = try IntervalsAthlete.parse(Data(json.utf8))
        XCTAssertEqual(athlete.name, "Test")
        XCTAssertEqual(athlete.ftp, 250)
        XCTAssertEqual(athlete.weight, 72.5)
        XCTAssertEqual(athlete.zones?.upperBounds, [55, 75, 90, 105, 120])
    }

    func testAthleteWithoutRideFTP() throws {
        let json = """
        { "name": "Läufer", "sportSettings": [ { "types": ["Ride"], "ftp": null }, { "types": ["Run"], "ftp": 276 } ] }
        """
        let athlete = try IntervalsAthlete.parse(Data(json.utf8))
        XCTAssertNil(athlete.ftp)
    }

    // MARK: FIT

    private func makeRide(seconds: Int = 120) -> (samples: [RideSample], laps: [RideLap], summary: RideSummary) {
        let start = Date(timeIntervalSince1970: 1_794_500_000)
        var samples: [RideSample] = []
        var distance = 0.0
        for i in 0..<seconds {
            let speed = 8.0
            distance += speed
            samples.append(RideSample(
                timestamp: start.addingTimeInterval(Double(i + 1)),
                elapsed: Double(i + 1),
                power: 200 + (i % 10),
                cadence: 90,
                heartRate: i < 5 ? nil : 140,
                speed: speed,
                distance: distance,
                altitude: 240 + Double(i) * 0.1,
                gradePercent: 1.2
            ))
        }
        let end = start.addingTimeInterval(Double(seconds + 1))
        let recorder = RideRecorder()
        for (i, sample) in samples.enumerated() {
            if i == 60 { recorder.markLap(at: start.addingTimeInterval(61), elapsed: 60) }
            recorder.add(sample)
        }
        recorder.finish(at: end, elapsed: Double(seconds))
        let summary = RideSummary.compute(samples: samples[...], startTime: start, endTime: end)
        return (samples, recorder.laps, summary)
    }

    func testSummary() {
        let ride = makeRide()
        XCTAssertEqual(ride.summary.distance, 960, accuracy: 0.01)
        XCTAssertEqual(ride.summary.movingTime, 120, accuracy: 0.01)
        XCTAssertEqual(ride.summary.avgCadence, 90)
        XCTAssertEqual(ride.summary.maxPower, 209)
        XCTAssertEqual(ride.laps.count, 2)
        XCTAssertGreaterThan(ride.summary.ascent, 11)
    }

    func testFITFileIsValid() throws {
        let ride = makeRide()
        let data = ActivityFITBuilder.build(samples: ride.samples, laps: ride.laps, summary: ride.summary)
        let bytes = [UInt8](data)

        // Header
        XCTAssertEqual(bytes[0], 14)
        XCTAssertEqual(Array(bytes[8..<12]), Array(".FIT".utf8))
        let dataSize = Int(bytes[4]) | Int(bytes[5]) << 8 | Int(bytes[6]) << 16 | Int(bytes[7]) << 24
        XCTAssertEqual(bytes.count, 14 + dataSize + 2)
        XCTAssertEqual(FITEncoder.crc(bytes[0..<12]), UInt16(bytes[12]) | UInt16(bytes[13]) << 8)
        // The CRC over the whole file including its CRC is 0.
        XCTAssertEqual(FITEncoder.crc(bytes), 0)

        let messages = try FITTestDecoder.decode(bytes)
        let records = messages.filter { $0.global == 20 }
        XCTAssertEqual(records.count, 120)
        XCTAssertEqual(records.first?.fields[7], 200) // power
        XCTAssertEqual(records.first?.fields[4], 90) // cadence
        XCTAssertEqual(records.first?.fields[3], 0xFF) // heart rate missing -> invalid
        XCTAssertEqual(records.last?.fields[5], 96_000) // distance in cm
        XCTAssertEqual(records.first?.fields[2], Int(((240 + 500) * 5.0).rounded())) // altitude

        let fileId = try XCTUnwrap(messages.first)
        XCTAssertEqual(fileId.global, 0)
        XCTAssertEqual(fileId.fields[0], 4) // activity

        let laps = messages.filter { $0.global == 19 }
        XCTAssertEqual(laps.count, 2)

        let session = try XCTUnwrap(messages.first { $0.global == 18 })
        XCTAssertEqual(session.fields[5], 2) // cycling
        XCTAssertEqual(session.fields[6], 58) // virtual activity
        XCTAssertEqual(session.fields[9], 96_000)
        XCTAssertEqual(session.fields[26], 2) // laps
        XCTAssertEqual(session.fields[8], 120_000) // timer time in ms

        let activity = try XCTUnwrap(messages.last)
        XCTAssertEqual(activity.global, 34)
        XCTAssertEqual(activity.fields[1], 1)
    }
}

/// Small FIT reader for the tests (normal headers only, no developer fields).
enum FITTestDecoder {
    struct Message {
        var global: Int
        var fields: [Int: Int]
    }

    enum DecodeError: Error { case truncated, unknownLocal(Int) }

    static func decode(_ bytes: [UInt8]) throws -> [Message] {
        let headerSize = Int(bytes[0])
        let dataSize = Int(bytes[4]) | Int(bytes[5]) << 8 | Int(bytes[6]) << 16 | Int(bytes[7]) << 24
        var i = headerSize
        let end = headerSize + dataSize
        var definitions: [Int: (global: Int, fields: [(number: Int, size: Int, base: UInt8)])] = [:]
        var messages: [Message] = []
        while i < end {
            let header = bytes[i]
            i += 1
            let local = Int(header & 0x0F)
            if header & 0x40 != 0 {
                guard i + 5 <= end else { throw DecodeError.truncated }
                let global = Int(bytes[i + 2]) | Int(bytes[i + 3]) << 8
                let count = Int(bytes[i + 4])
                i += 5
                var fields: [(Int, Int, UInt8)] = []
                for _ in 0..<count {
                    fields.append((Int(bytes[i]), Int(bytes[i + 1]), bytes[i + 2]))
                    i += 3
                }
                definitions[local] = (global, fields)
            } else {
                guard let def = definitions[local] else { throw DecodeError.unknownLocal(local) }
                var values: [Int: Int] = [:]
                for field in def.fields {
                    guard i + field.size <= end else { throw DecodeError.truncated }
                    var raw: UInt64 = 0
                    for b in 0..<field.size { raw |= UInt64(bytes[i + b]) << (8 * UInt64(b)) }
                    i += field.size
                    if field.base == 0x83 { // sint16
                        values[field.number] = Int(Int16(bitPattern: UInt16(raw)))
                    } else {
                        values[field.number] = Int(raw)
                    }
                }
                messages.append(Message(global: def.global, fields: values))
            }
        }
        return messages
    }
}
