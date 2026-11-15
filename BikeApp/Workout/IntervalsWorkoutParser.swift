import Foundation

/// Turns intervals.icu events and library workouts (with `workout_doc`) into `Workout` values.
enum IntervalsWorkoutParser {
    /// Midpoints of the power zones in fraction of FTP, used for zone-based targets.
    static let zoneMidpoints: [Double] = [0.5, 0.65, 0.83, 0.98, 1.13, 1.35, 1.6]

    static let rideTypes: Set<String> = ["Ride", "VirtualRide", "GravelRide", "MountainBikeRide", "EBikeRide", "TrackRide"]

    static func parseEvents(_ data: Data, fallbackFTP: Double) throws -> [Workout] {
        let json = try JSONSerialization.jsonObject(with: data)
        guard let array = json as? [[String: Any]] else { return [] }
        return array.compactMap { parseEvent($0, fallbackFTP: fallbackFTP) }
    }

    static func parseEvent(_ event: [String: Any], fallbackFTP: Double) -> Workout? {
        if let type = event["type"] as? String, !rideTypes.contains(type) { return nil }
        guard let doc = event["workout_doc"] as? [String: Any] else { return nil }
        let ftp = (doc["ftp"] as? Double) ?? (doc["ftp"] as? Int).map(Double.init) ?? fallbackFTP
        let steps = flatten(doc["steps"] as? [[String: Any]] ?? [], ftp: ftp)
        guard !steps.isEmpty else { return nil }
        let idValue = event["id"]
        let eventId = (idValue as? Int) ?? (idValue as? String).flatMap(Int.init)
        let id = eventId.map { "event-\($0)" } ?? "workout-\((idValue as? String) ?? UUID().uuidString)"
        return Workout(
            id: id,
            name: (event["name"] as? String) ?? "Workout",
            date: (event["start_date_local"] as? String).flatMap(parseLocalDate),
            eventId: event["category"] != nil ? eventId : nil,
            description: event["description"] as? String,
            steps: steps
        )
    }

    static func parseLibrary(_ data: Data, fallbackFTP: Double) throws -> [Workout] {
        let json = try JSONSerialization.jsonObject(with: data)
        guard let array = json as? [[String: Any]] else { return [] }
        return array.compactMap { item in
            var copy = item
            copy.removeValue(forKey: "category")
            return parseEvent(copy, fallbackFTP: fallbackFTP)
        }
    }

    /// Expands repeats and converts every step to a fraction of FTP.
    static func flatten(_ steps: [[String: Any]], ftp: Double) -> [WorkoutStep] {
        var result: [WorkoutStep] = []
        for step in steps {
            if let children = step["steps"] as? [[String: Any]] {
                let reps = Swift.max(1, number(step["reps"]).map { Int($0) } ?? 1)
                let inner = flatten(children, ftp: ftp)
                for _ in 0..<reps { result.append(contentsOf: inner) }
                continue
            }
            guard let parsed = parseStep(step, ftp: ftp) else { continue }
            result.append(parsed)
        }
        return result
    }

    static func parseStep(_ step: [String: Any], ftp: Double) -> WorkoutStep? {
        var duration = number(step["duration"]) ?? 0
        if duration <= 0, let distance = number(step["distance"]) {
            duration = distance / (30 / 3.6)
        }
        guard duration > 0 else { return nil }
        let label = step["text"] as? String
        if (step["freeride"] as? Bool) == true {
            return .free(duration, label: label)
        }
        guard let power = step["power"] as? [String: Any] else {
            return .free(duration, label: label)
        }
        let units = (power["units"] as? String)?.lowercased() ?? "%ftp"
        let ramp = (step["ramp"] as? Bool) == true

        func fraction(_ value: Double) -> Double? {
            switch units {
            case "%ftp", "percent_ftp": return value / 100
            case "w", "watts": return ftp > 0 ? value / ftp : nil
            case "power_zone", "zone":
                let i = Int(value.rounded()) - 1
                return zoneMidpoints[Swift.min(zoneMidpoints.count - 1, Swift.max(0, i))]
            default: return nil
            }
        }

        if let value = number(power["value"]), let f = fraction(value) {
            return .steady(duration, f, label: label)
        }
        if let start = number(power["start"]), let end = number(power["end"]),
           let fs = fraction(start), let fe = fraction(end) {
            if ramp {
                return .ramp(duration, from: fs, to: fe, label: label)
            }
            return .steady(duration, (fs + fe) / 2, label: label)
        }
        // Fall back to resolved absolute values if present.
        if let resolved = step["_power"] as? [String: Any], ftp > 0 {
            if let v = number(resolved["value"]) { return .steady(duration, v / ftp, label: label) }
            if let s = number(resolved["start"]), let e = number(resolved["end"]) {
                return ramp ? .ramp(duration, from: s / ftp, to: e / ftp, label: label) : .steady(duration, (s + e) / 2 / ftp, label: label)
            }
        }
        return .free(duration, label: label)
    }

    static func number(_ value: Any?) -> Double? {
        switch value {
        case let d as Double: return d
        case let i as Int: return Double(i)
        case let n as NSNumber: return n.doubleValue
        case let s as String: return Double(s)
        default: return nil
        }
    }

    static func parseLocalDate(_ string: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        if let d = formatter.date(from: string) { return d }
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: String(string.prefix(10)))
    }
}

/// Athlete data from intervals.icu that the app uses.
struct IntervalsAthlete: Equatable {
    var name: String?
    var ftp: Int?
    var weight: Double?
    var zones: PowerZones?

    /// Id and FTP values of the cycling sport settings.
    static func rideSettings(_ data: Data) -> (id: Int, ftp: Int?, indoorFTP: Int?)? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let settings = json["sportSettings"] as? [[String: Any]] else { return nil }
        guard let ride = settings.first(where: { (($0["types"] as? [String]) ?? []).contains { IntervalsWorkoutParser.rideTypes.contains($0) } }),
              let id = IntervalsWorkoutParser.number(ride["id"]) else { return nil }
        return (Int(id), IntervalsWorkoutParser.number(ride["ftp"]).map { Int($0.rounded()) }, IntervalsWorkoutParser.number(ride["indoor_ftp"]).map { Int($0.rounded()) })
    }

    static func parse(_ data: Data) throws -> IntervalsAthlete {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return IntervalsAthlete() }
        var athlete = IntervalsAthlete()
        athlete.name = json["name"] as? String
        athlete.weight = IntervalsWorkoutParser.number(json["icu_weight"]) ?? IntervalsWorkoutParser.number(json["weight"])
        let settings = json["sportSettings"] as? [[String: Any]] ?? []
        let ride = settings.first { (($0["types"] as? [String]) ?? []).contains { IntervalsWorkoutParser.rideTypes.contains($0) } }
        if let ride {
            let ftp = IntervalsWorkoutParser.number(ride["indoor_ftp"]) ?? IntervalsWorkoutParser.number(ride["ftp"])
            athlete.ftp = ftp.map { Int($0.rounded()) }
            if let bounds = ride["power_zones"] as? [Any] {
                let values = bounds.compactMap { IntervalsWorkoutParser.number($0) }
                if values.count >= 5 { athlete.zones = PowerZones(upperBounds: Array(values.prefix(5))) }
            }
        }
        return athlete
    }
}
