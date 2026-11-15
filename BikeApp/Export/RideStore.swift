import Foundation

/// Key figures of a stored ride.
struct StoredSummary: Codable, Equatable {
    var movingTime: TimeInterval
    var elapsedTime: TimeInterval
    var distance: Double
    var avgPower: Int
    var maxPower: Int
    var normalizedPower: Int
    var avgCadence: Int?
    var avgHeartRate: Int?
    var maxHeartRate: Int?
    var avgSpeed: Double
    var maxSpeed: Double
    var ascent: Double
    var kilojoules: Double

    init(_ s: RideSummary) {
        movingTime = s.movingTime
        elapsedTime = s.elapsedTime
        distance = s.distance
        avgPower = s.avgPower
        maxPower = s.maxPower
        normalizedPower = s.normalizedPower
        avgCadence = s.avgCadence
        avgHeartRate = s.avgHeartRate
        maxHeartRate = s.maxHeartRate
        avgSpeed = s.avgSpeed
        maxSpeed = s.maxSpeed
        ascent = s.ascent
        kilojoules = s.kilojoules
    }
}

/// Downsampled curves of a ride for the charts (at most a few hundred points).
struct StoredSeries: Codable, Equatable {
    var bucketSeconds: Double
    var power: [Int]
    /// 0 = no heart rate in this bucket.
    var heartRate: [Int]
    var cadence: [Int]
    var altitude: [Double]
    var distance: [Double]

    static func make(from samples: [RideSample], maxPoints: Int = 360) -> StoredSeries {
        let n = samples.count
        guard n > 0 else { return StoredSeries(bucketSeconds: 1, power: [], heartRate: [], cadence: [], altitude: [], distance: []) }
        let bucket = Swift.max(1, Int((Double(n) / Double(maxPoints)).rounded(.up)))
        var series = StoredSeries(bucketSeconds: Double(bucket), power: [], heartRate: [], cadence: [], altitude: [], distance: [])
        for start in stride(from: 0, to: n, by: bucket) {
            let slice = samples[start..<Swift.min(n, start + bucket)]
            let count = Double(slice.count)
            series.power.append(Int((Double(slice.reduce(0) { $0 + $1.power }) / count).rounded()))
            let hrs = slice.compactMap(\.heartRate).filter { $0 > 0 }
            series.heartRate.append(hrs.isEmpty ? 0 : Int((Double(hrs.reduce(0, +)) / Double(hrs.count)).rounded()))
            let cads = slice.compactMap(\.cadence).filter { $0 > 0 }
            series.cadence.append(cads.isEmpty ? 0 : Int((Double(cads.reduce(0, +)) / Double(cads.count)).rounded()))
            series.altitude.append(slice.last?.altitude ?? 0)
            series.distance.append(slice.last?.distance ?? 0)
        }
        return series
    }
}

/// Keeps every finished ride on disk (FIT file plus metadata) and uploads rides that are not on intervals.icu yet.
///
/// Rides are saved before any upload attempt, so a ride without API key or without network
/// is uploaded later: when a key is saved, when the app starts and when it becomes active.
/// The FIT file is what intervals.icu needs; the metadata holds the figures and curves for the history.
@MainActor
final class RideStore {
    struct Entry: Codable, Identifiable, Equatable {
        /// FIT file name, also the id.
        var id: String
        var name: String
        var description: String?
        var pairedEventId: Int?
        var date: Date
        var distance: Double
        var movingTime: TimeInterval
        var uploadedActivityId: String?
        var lastError: String?
        /// Course or workout, shown under the name.
        var subtitle: String?
        var summary: StoredSummary?
        var series: StoredSeries?
        /// Seconds in Z1…Z6.
        var zoneSeconds: [Double]?
        var ftp: Int?
        /// FTP found by an FTP test in this ride.
        var ftpTestResult: Int?

        var isUploaded: Bool { uploadedActivityId != nil }

        static func make(id: String, name: String, subtitle: String?, description: String?, pairedEventId: Int?,
                         samples: [RideSample], summary: RideSummary, ftp: Int, zones: PowerZones) -> Entry {
            var zoneSeconds = Array(repeating: 0.0, count: 6)
            for s in samples where s.power > 0 {
                zoneSeconds[zones.index(watts: Double(s.power), ftp: Double(ftp))] += 1
            }
            return Entry(
                id: id, name: name, description: description, pairedEventId: pairedEventId,
                date: summary.startTime, distance: summary.distance, movingTime: summary.movingTime,
                subtitle: subtitle,
                summary: StoredSummary(summary),
                series: StoredSeries.make(from: samples),
                zoneSeconds: zoneSeconds,
                ftp: ftp
            )
        }
    }

    let directory: URL
    private var uploading = false

    init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            self.directory = base.appendingPathComponent("BikeApp/Rides", isDirectory: true)
            migrateOldQueue(from: base.appendingPathComponent("BikeApp/Pending", isDirectory: true))
        }
    }

    private func metaURL(_ id: String) -> URL { directory.appendingPathComponent(id + ".json") }
    private func fitURL(_ id: String) -> URL { directory.appendingPathComponent(id) }

    func save(fit: Data, entry: Entry) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try fit.write(to: fitURL(entry.id), options: .atomic)
            try write(entry)
        } catch {
            NSLog("BikeApp: could not store ride: \(error)")
        }
    }

    private func write(_ entry: Entry) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(entry).write(to: metaURL(entry.id), options: .atomic)
    }

    func entries() -> [Entry] {
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return files.filter { $0.hasSuffix(".json") }
            .compactMap { try? decoder.decode(Entry.self, from: Data(contentsOf: directory.appendingPathComponent($0))) }
            .sorted { $0.date > $1.date }
    }

    var pending: [Entry] { entries().filter { !$0.isUploaded } }

    func entry(id: String) -> Entry? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: metaURL(id)) else { return nil }
        return try? decoder.decode(Entry.self, from: data)
    }

    func fit(for id: String) -> Data? { try? Data(contentsOf: fitURL(id)) }

    func update(_ id: String, _ change: (inout Entry) -> Void) {
        guard var entry = entry(id: id) else { return }
        change(&entry)
        try? write(entry)
    }

    /// Deletes a ride from this Mac (not from intervals.icu).
    func delete(id: String) {
        try? FileManager.default.removeItem(at: fitURL(id))
        try? FileManager.default.removeItem(at: metaURL(id))
    }

    /// Uploads one stored ride. Returns the activity id.
    @discardableResult
    func upload(id: String, using client: IntervalsClient) async throws -> String {
        guard let entry = entry(id: id), let fit = fit(for: id) else { throw IntervalsError.invalidResponse }
        do {
            let activity = try await client.upload(fit: fit, filename: entry.id, name: entry.name, description: entry.description, pairedEventId: entry.pairedEventId)
            update(id) {
                $0.uploadedActivityId = activity.isEmpty ? "ok" : activity
                $0.lastError = nil
            }
            return activity
        } catch {
            update(id) { $0.lastError = error.localizedDescription }
            throw error
        }
    }

    /// Uploads every ride that is not on intervals.icu yet. Returns the number of uploads.
    @discardableResult
    func uploadPending(using client: IntervalsClient) async -> Int {
        guard client.isConfigured, !uploading else { return 0 }
        uploading = true
        defer { uploading = false }
        var done = 0
        for entry in pending {
            if (try? await upload(id: entry.id, using: client)) != nil { done += 1 }
        }
        return done
    }

    /// Creates the history entry for a FIT file: figures and curves are read from the file.
    func makeEntry(fit data: Data, id: String, fallbackName: String, ftp: Int, zones: PowerZones) throws -> Entry {
        let ride = try FITDecoder.ride(from: data)
        let first = ride.samples.first?.timestamp ?? Date()
        let last = ride.samples.last?.timestamp ?? first
        var summary = RideSummary.compute(samples: ride.samples[...], startTime: first, endTime: last)
        if let moving = ride.movingTime, moving > 0 { summary.movingTime = moving }
        let name = summary.distance > 0 ? "Bike App – \(Fmt.km(summary.distance)) km" : fallbackName
        return Entry.make(id: id, name: name, subtitle: "Importiert", description: "Gefahren mit Bike App", pairedEventId: nil,
                          samples: ride.samples, summary: summary, ftp: ftp, zones: zones)
    }

    /// Adds a FIT file from disk (for example one saved by hand) to the store.
    func importFIT(from url: URL, ftp: Int, zones: PowerZones) throws -> Entry {
        let data = try Data(contentsOf: url)
        var id = url.lastPathComponent.hasSuffix(".fit") ? url.lastPathComponent : url.lastPathComponent + ".fit"
        if entry(id: id) != nil, fit(for: id) != data {
            id = url.deletingPathExtension().lastPathComponent + "-\(UUID().uuidString.prefix(6)).fit"
        }
        let entry = try makeEntry(fit: data, id: id, fallbackName: url.deletingPathExtension().lastPathComponent, ftp: ftp, zones: zones)
        save(fit: data, entry: entry)
        return entry
    }

    /// FIT files placed in the folder by hand get a history entry.
    func adoptLooseFiles(ftp: Int, zones: PowerZones) {
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        for file in files where file.lowercased().hasSuffix(".fit") && !files.contains(file + ".json") {
            guard let data = fit(for: file),
                  let entry = try? makeEntry(fit: data, id: file, fallbackName: file, ftp: ftp, zones: zones) else { continue }
            try? write(entry)
        }
    }

    /// Fills in figures and curves for entries created before the history existed.
    func completeDetails(ftp: Int, zones: PowerZones) {
        for old in entries() where old.series == nil {
            guard let data = fit(for: old.id), var entry = try? makeEntry(fit: data, id: old.id, fallbackName: old.name, ftp: ftp, zones: zones) else { continue }
            entry.name = old.name
            entry.subtitle = old.subtitle
            entry.description = old.description
            entry.pairedEventId = old.pairedEventId
            entry.uploadedActivityId = old.uploadedActivityId
            entry.lastError = old.lastError
            try? write(entry)
        }
    }

    /// Moves files of the first version's upload queue into the store.
    private func migrateOldQueue(from old: URL) {
        struct OldPending: Codable { var filename: String; var name: String; var description: String?; var pairedEventId: Int? }
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: old.path) else { return }
        for meta in files where meta.hasSuffix(".json") {
            guard let data = try? Data(contentsOf: old.appendingPathComponent(meta)),
                  let p = try? JSONDecoder().decode(OldPending.self, from: data),
                  let fit = try? Data(contentsOf: old.appendingPathComponent(p.filename)) else { continue }
            save(fit: fit, entry: Entry(id: p.filename, name: p.name, description: p.description, pairedEventId: p.pairedEventId, date: Date(), distance: 0, movingTime: 0))
            try? FileManager.default.removeItem(at: old.appendingPathComponent(meta))
            try? FileManager.default.removeItem(at: old.appendingPathComponent(p.filename))
        }
    }
}
