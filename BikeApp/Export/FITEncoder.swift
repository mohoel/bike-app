import Foundation

/// Minimal writer for the Garmin FIT file format (activity files).
struct FITEncoder {
    enum BaseType: UInt8 {
        case enumeration = 0x00
        case uint8 = 0x02
        case sint16 = 0x83
        case uint16 = 0x84
        case uint32 = 0x86
        case uint32z = 0x8C

        var size: Int {
            switch self {
            case .enumeration, .uint8: return 1
            case .sint16, .uint16: return 2
            case .uint32, .uint32z: return 4
            }
        }

        /// The "invalid" value FIT readers treat as "no data".
        var invalid: UInt64 {
            switch self {
            case .enumeration, .uint8: return 0xFF
            case .sint16: return 0x7FFF
            case .uint16: return 0xFFFF
            case .uint32: return 0xFFFF_FFFF
            case .uint32z: return 0
            }
        }
    }

    struct Field {
        var number: UInt8
        var type: BaseType
    }

    /// Seconds between the Unix epoch and the FIT epoch (1989-12-31 00:00 UTC).
    static let epochOffset: TimeInterval = 631_065_600

    private(set) var records: [UInt8] = []
    private var definitions: [UInt8: [Field]] = [:]

    mutating func define(local: UInt8, global: UInt16, fields: [Field]) {
        precondition(local < 16)
        records.append(0x40 | local)
        records.append(0) // reserved
        records.append(0) // little endian
        records.append(UInt8(global & 0xFF))
        records.append(UInt8(global >> 8))
        records.append(UInt8(fields.count))
        for f in fields {
            records.append(f.number)
            records.append(UInt8(f.type.size))
            records.append(f.type.rawValue)
        }
        definitions[local] = fields
    }

    /// Writes a data message. `nil` values are written as the FIT invalid value.
    mutating func write(local: UInt8, _ values: [Int?]) {
        guard let fields = definitions[local] else { preconditionFailure("message \(local) not defined") }
        precondition(values.count == fields.count)
        records.append(local)
        for (field, value) in zip(fields, values) {
            let raw: UInt64
            if let value {
                raw = UInt64(bitPattern: Int64(value))
            } else {
                raw = field.type.invalid
            }
            for i in 0..<field.type.size {
                records.append(UInt8(truncatingIfNeeded: raw >> (8 * UInt64(i))))
            }
        }
    }

    /// Complete file: 14-byte header, records, file CRC.
    func data() -> Data {
        var header: [UInt8] = [14, 0x20]
        let profile: UInt16 = 2160
        header.append(UInt8(profile & 0xFF))
        header.append(UInt8(profile >> 8))
        let size = UInt32(records.count)
        for i in 0..<4 { header.append(UInt8(truncatingIfNeeded: size >> (8 * UInt32(i)))) }
        header.append(contentsOf: Array(".FIT".utf8))
        let headerCRC = Self.crc(header)
        header.append(UInt8(headerCRC & 0xFF))
        header.append(UInt8(headerCRC >> 8))
        var file = header + records
        let fileCRC = Self.crc(file)
        file.append(UInt8(fileCRC & 0xFF))
        file.append(UInt8(fileCRC >> 8))
        return Data(file)
    }

    static func timestamp(_ date: Date) -> Int {
        Int(Swift.max(0, date.timeIntervalSince1970 - epochOffset))
    }

    private static let crcTable: [UInt16] = [
        0x0000, 0xCC01, 0xD801, 0x1400, 0xF001, 0x3C00, 0x2800, 0xE401,
        0xA001, 0x6C00, 0x7800, 0xB401, 0x5000, 0x9C01, 0x8801, 0x4400,
    ]

    static func crc<S: Sequence>(_ bytes: S, initial: UInt16 = 0) -> UInt16 where S.Element == UInt8 {
        var crc = initial
        for byte in bytes {
            var tmp = crcTable[Int(crc & 0xF)]
            crc = (crc >> 4) & 0x0FFF
            crc = crc ^ tmp ^ crcTable[Int(byte & 0xF)]
            tmp = crcTable[Int(crc & 0xF)]
            crc = (crc >> 4) & 0x0FFF
            crc = crc ^ tmp ^ crcTable[Int((byte >> 4) & 0xF)]
        }
        return crc
    }
}

/// Builds a FIT activity file from a recorded ride.
enum ActivityFITBuilder {
    // Global message numbers
    private static let fileId: UInt16 = 0
    private static let session: UInt16 = 18
    private static let lap: UInt16 = 19
    private static let record: UInt16 = 20
    private static let event: UInt16 = 21
    private static let activity: UInt16 = 34

    // Enum values
    private static let sportCycling = 2
    private static let subSportVirtual = 58

    static func build(samples: [RideSample], laps: [RideLap], summary: RideSummary) -> Data {
        var fit = FITEncoder()
        let start = FITEncoder.timestamp(summary.startTime)
        let end = FITEncoder.timestamp(summary.endTime)

        fit.define(local: 0, global: fileId, fields: [
            .init(number: 0, type: .enumeration), // type
            .init(number: 1, type: .uint16), // manufacturer
            .init(number: 2, type: .uint16), // product
            .init(number: 3, type: .uint32z), // serial number
            .init(number: 4, type: .uint32), // time created
        ])
        fit.write(local: 0, [4, 255, 1, 20_261_112, start])

        fit.define(local: 1, global: event, fields: [
            .init(number: 253, type: .uint32),
            .init(number: 0, type: .enumeration), // event
            .init(number: 1, type: .enumeration), // event type
        ])
        fit.write(local: 1, [start, 0, 0]) // timer start

        fit.define(local: 2, global: record, fields: [
            .init(number: 253, type: .uint32), // timestamp
            .init(number: 2, type: .uint16), // altitude, scale 5, offset 500
            .init(number: 3, type: .uint8), // heart rate
            .init(number: 4, type: .uint8), // cadence
            .init(number: 5, type: .uint32), // distance, scale 100
            .init(number: 6, type: .uint16), // speed, scale 1000
            .init(number: 7, type: .uint16), // power
            .init(number: 9, type: .sint16), // grade, scale 100
        ])
        for s in samples {
            fit.write(local: 2, [
                FITEncoder.timestamp(s.timestamp),
                Int(((s.altitude + 500) * 5).rounded()),
                s.heartRate.map { Swift.min(254, Swift.max(0, $0)) },
                s.cadence.map { Swift.min(254, Swift.max(0, $0)) },
                Int((s.distance * 100).rounded()),
                Int((s.speed * 1000).rounded()),
                Swift.min(65_534, Swift.max(0, s.power)),
                Int((s.gradePercent * 100).rounded()),
            ])
        }
        fit.write(local: 1, [end, 0, 4]) // timer stop all

        fit.define(local: 3, global: lap, fields: [
            .init(number: 254, type: .uint16), // message index
            .init(number: 253, type: .uint32), // timestamp
            .init(number: 0, type: .enumeration), // event
            .init(number: 1, type: .enumeration), // event type
            .init(number: 2, type: .uint32), // start time
            .init(number: 7, type: .uint32), // total elapsed time, ms
            .init(number: 8, type: .uint32), // total timer time, ms
            .init(number: 9, type: .uint32), // total distance, cm
            .init(number: 13, type: .uint16), // avg speed
            .init(number: 14, type: .uint16), // max speed
            .init(number: 15, type: .uint8), // avg heart rate
            .init(number: 16, type: .uint8), // max heart rate
            .init(number: 17, type: .uint8), // avg cadence
            .init(number: 18, type: .uint8), // max cadence
            .init(number: 19, type: .uint16), // avg power
            .init(number: 20, type: .uint16), // max power
            .init(number: 21, type: .uint16), // total ascent
            .init(number: 25, type: .enumeration), // sport
            .init(number: 39, type: .enumeration), // sub sport
        ])
        let lapList = laps.isEmpty
            ? [RideLap(startTime: summary.startTime, endTime: summary.endTime, startElapsed: 0, endElapsed: summary.movingTime, sampleRange: 0..<samples.count)]
            : laps
        for (i, l) in lapList.enumerated() {
            let slice = samples[l.sampleRange.clamped(to: 0..<samples.count)]
            let ls = RideSummary.compute(samples: slice, startTime: l.startTime, endTime: l.endTime)
            fit.write(local: 3, [
                i,
                FITEncoder.timestamp(l.endTime),
                9, 1,
                FITEncoder.timestamp(l.startTime),
                Int(ls.elapsedTime * 1000),
                Int(ls.movingTime * 1000),
                Int((ls.distance * 100).rounded()),
                Int((ls.avgSpeed * 1000).rounded()),
                Int((ls.maxSpeed * 1000).rounded()),
                ls.avgHeartRate, ls.maxHeartRate,
                ls.avgCadence, ls.maxCadence,
                ls.avgPower, ls.maxPower,
                Int(ls.ascent.rounded()),
                sportCycling, subSportVirtual,
            ])
        }

        fit.define(local: 4, global: session, fields: [
            .init(number: 254, type: .uint16), // message index
            .init(number: 253, type: .uint32), // timestamp
            .init(number: 0, type: .enumeration), // event
            .init(number: 1, type: .enumeration), // event type
            .init(number: 2, type: .uint32), // start time
            .init(number: 5, type: .enumeration), // sport
            .init(number: 6, type: .enumeration), // sub sport
            .init(number: 7, type: .uint32), // total elapsed time
            .init(number: 8, type: .uint32), // total timer time
            .init(number: 9, type: .uint32), // total distance
            .init(number: 11, type: .uint16), // total calories
            .init(number: 14, type: .uint16), // avg speed
            .init(number: 15, type: .uint16), // max speed
            .init(number: 16, type: .uint8), // avg heart rate
            .init(number: 17, type: .uint8), // max heart rate
            .init(number: 18, type: .uint8), // avg cadence
            .init(number: 19, type: .uint8), // max cadence
            .init(number: 20, type: .uint16), // avg power
            .init(number: 21, type: .uint16), // max power
            .init(number: 22, type: .uint16), // total ascent
            .init(number: 25, type: .uint16), // first lap index
            .init(number: 26, type: .uint16), // num laps
            .init(number: 28, type: .enumeration), // trigger
            .init(number: 34, type: .uint16), // normalized power
        ])
        fit.write(local: 4, [
            0,
            end,
            8, 1,
            start,
            sportCycling, subSportVirtual,
            Int(summary.elapsedTime * 1000),
            Int(summary.movingTime * 1000),
            Int((summary.distance * 100).rounded()),
            Int(summary.kilojoules.rounded()),
            Int((summary.avgSpeed * 1000).rounded()),
            Int((summary.maxSpeed * 1000).rounded()),
            summary.avgHeartRate, summary.maxHeartRate,
            summary.avgCadence, summary.maxCadence,
            summary.avgPower, summary.maxPower,
            Int(summary.ascent.rounded()),
            0, lapList.count,
            0,
            summary.normalizedPower,
        ])

        fit.define(local: 5, global: activity, fields: [
            .init(number: 253, type: .uint32), // timestamp
            .init(number: 0, type: .uint32), // total timer time
            .init(number: 1, type: .uint16), // num sessions
            .init(number: 2, type: .enumeration), // type
            .init(number: 3, type: .enumeration), // event
            .init(number: 4, type: .enumeration), // event type
            .init(number: 5, type: .uint32), // local timestamp
        ])
        let offset = TimeZone.current.secondsFromGMT(for: summary.endTime)
        fit.write(local: 5, [end, Int(summary.movingTime * 1000), 1, 0, 26, 1, end + offset])

        return fit.data()
    }
}
