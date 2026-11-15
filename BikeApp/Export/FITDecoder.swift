import Foundation

/// Reads FIT activity files, so rides saved by hand (or from other apps) can be shown and uploaded.
enum FITDecoder {
    struct Message {
        var global: Int
        /// Raw field values by field number; invalid values are left out.
        var fields: [Int: Int64]
    }

    enum DecodeError: LocalizedError {
        case notFIT
        case truncated
        case noRecords

        var errorDescription: String? {
            switch self {
            case .notFIT: return "Das ist keine FIT-Datei."
            case .truncated: return "Die FIT-Datei ist unvollständig."
            case .noRecords: return "Die FIT-Datei enthält keine Fahrtdaten."
            }
        }
    }

    private struct Definition {
        var global: Int
        var bigEndian: Bool
        var fields: [(number: Int, size: Int, base: UInt8)]
        var developerBytes: Int
    }

    static func messages(_ data: Data) throws -> [Message] {
        let b = [UInt8](data)
        guard b.count >= 12, Array(b[8..<12]) == Array(".FIT".utf8) else { throw DecodeError.notFIT }
        let headerSize = Int(b[0])
        let dataSize = Int(b[4]) | Int(b[5]) << 8 | Int(b[6]) << 16 | Int(b[7]) << 24
        let end = Swift.min(b.count, headerSize + dataSize)
        var i = headerSize
        var definitions: [Int: Definition] = [:]
        var lastTimestamp: Int64 = 0
        var messages: [Message] = []

        func readFields(_ def: Definition) throws -> Message {
            var values: [Int: Int64] = [:]
            for field in def.fields {
                guard i + field.size <= end else { throw DecodeError.truncated }
                if let value = decode(Array(b[i..<(i + field.size)]), base: field.base, bigEndian: def.bigEndian) {
                    values[field.number] = value
                }
                i += field.size
            }
            guard i + def.developerBytes <= end else { throw DecodeError.truncated }
            i += def.developerBytes
            return Message(global: def.global, fields: values)
        }

        while i < end {
            let header = b[i]
            i += 1
            if header & 0x80 != 0 {
                // Compressed timestamp header: the low 5 bits are a time offset.
                let local = Int((header >> 5) & 0x03)
                guard let def = definitions[local] else { throw DecodeError.truncated }
                var message = try readFields(def)
                let offset = Int64(header & 0x1F)
                var timestamp = (lastTimestamp & ~0x1F) + offset
                if timestamp < lastTimestamp { timestamp += 0x20 }
                lastTimestamp = timestamp
                message.fields[253] = timestamp
                messages.append(message)
                continue
            }
            let local = Int(header & 0x0F)
            if header & 0x40 != 0 {
                guard i + 5 <= end else { throw DecodeError.truncated }
                let bigEndian = b[i + 1] == 1
                let global = bigEndian ? Int(b[i + 2]) << 8 | Int(b[i + 3]) : Int(b[i + 2]) | Int(b[i + 3]) << 8
                let count = Int(b[i + 4])
                i += 5
                var fields: [(Int, Int, UInt8)] = []
                for _ in 0..<count {
                    guard i + 3 <= end else { throw DecodeError.truncated }
                    fields.append((Int(b[i]), Int(b[i + 1]), b[i + 2]))
                    i += 3
                }
                var developerBytes = 0
                if header & 0x20 != 0 {
                    guard i < end else { throw DecodeError.truncated }
                    let n = Int(b[i])
                    i += 1
                    for _ in 0..<n {
                        guard i + 3 <= end else { throw DecodeError.truncated }
                        developerBytes += Int(b[i + 1])
                        i += 3
                    }
                }
                definitions[local] = Definition(global: global, bigEndian: bigEndian, fields: fields, developerBytes: developerBytes)
            } else {
                guard let def = definitions[local] else { throw DecodeError.truncated }
                let message = try readFields(def)
                if let ts = message.fields[253] { lastTimestamp = ts }
                messages.append(message)
            }
        }
        return messages
    }

    /// One integer value of a field, or nil for invalid values, strings, floats and arrays.
    private static func decode(_ bytes: [UInt8], base: UInt8, bigEndian: Bool) -> Int64? {
        let sizes: [UInt8: Int] = [0x00: 1, 0x01: 1, 0x02: 1, 0x0A: 1, 0x0D: 1, 0x83: 2, 0x84: 2, 0x8B: 2, 0x85: 4, 0x86: 4, 0x8C: 4]
        guard let size = sizes[base], bytes.count == size else { return nil }
        var raw: UInt64 = 0
        for byte in bigEndian ? bytes : bytes.reversed() {
            raw = raw << 8 | UInt64(byte)
        }
        switch base {
        case 0x00, 0x02, 0x0D: return raw == 0xFF ? nil : Int64(raw)
        case 0x0A: return raw == 0 ? nil : Int64(raw)
        case 0x01: return raw == 0x7F ? nil : Int64(Int8(bitPattern: UInt8(raw)))
        case 0x84: return raw == 0xFFFF ? nil : Int64(raw)
        case 0x8B: return raw == 0 ? nil : Int64(raw)
        case 0x83: return raw == 0x7FFF ? nil : Int64(Int16(bitPattern: UInt16(raw)))
        case 0x86: return raw == 0xFFFF_FFFF ? nil : Int64(raw)
        case 0x8C: return raw == 0 ? nil : Int64(raw)
        case 0x85: return raw == 0x7FFF_FFFF ? nil : Int64(Int32(bitPattern: UInt32(raw)))
        default: return nil
        }
    }

    /// Ride samples from the record messages, plus the moving time from the session if present.
    static func ride(from data: Data) throws -> (samples: [RideSample], movingTime: TimeInterval?) {
        let all = try messages(data)
        var samples: [RideSample] = []
        var first: Int64?
        for m in all where m.global == 20 {
            guard let ts = m.fields[253] else { continue }
            if first == nil { first = ts }
            let altitude = (m.fields[78] ?? m.fields[2]).map { Double($0) / 5 - 500 } ?? samples.last?.altitude ?? 0
            let speed = (m.fields[73] ?? m.fields[6]).map { Double($0) / 1000 } ?? 0
            let distance = m.fields[5].map { Double($0) / 100 } ?? samples.last?.distance ?? 0
            samples.append(RideSample(
                timestamp: Date(timeIntervalSince1970: Double(ts) + FITEncoder.epochOffset),
                elapsed: Double(ts - (first ?? ts)),
                power: Int(m.fields[7] ?? 0),
                cadence: m.fields[4].map { Int($0) },
                heartRate: m.fields[3].map { Int($0) },
                speed: speed,
                distance: distance,
                altitude: altitude,
                gradePercent: m.fields[9].map { Double($0) / 100 } ?? 0
            ))
        }
        guard !samples.isEmpty else { throw DecodeError.noRecords }
        let session = all.first { $0.global == 18 }
        let moving = session?.fields[8].map { Double($0) / 1000 }
        return (samples, moving)
    }
}
