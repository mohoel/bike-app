import Foundation
import Observation

/// One FTP change in intervals.icu, kept so it can be undone.
struct FTPChange: Equatable {
    var settingsId: Int
    /// "ftp" or "indoor_ftp"
    var field: String
    var previous: Int?
    var new: Int?
}

enum IntervalsError: LocalizedError {
    case notConfigured
    case http(Int, String)
    case invalidResponse
    case noRideSettings

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Kein API-Key für intervals.icu hinterlegt."
        case .noRideSettings: return "In intervals.icu gibt es keine Einstellungen für Radfahren."
        case let .http(code, body):
            if code == 401 || code == 403 { return "intervals.icu lehnt den API-Key ab (\(code))." }
            return "intervals.icu antwortet mit Fehler \(code). \(body.prefix(160))"
        case .invalidResponse: return "Unerwartete Antwort von intervals.icu."
        }
    }
}

/// REST client for intervals.icu (planned workouts, athlete data, activity upload).
@Observable @MainActor
final class IntervalsClient {
    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    private(set) var upcoming: [Workout] = []
    private(set) var library: [Workout] = []
    private(set) var state: LoadState = .idle
    private(set) var athlete: IntervalsAthlete?
    private(set) var apiKey: String
    private(set) var lastRefresh: Date?

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let session: URLSession
    @ObservationIgnored private let keychainAccount: String

    nonisolated static let keychainAccount = "api-key"

    /// `keychainAccount` lets tests use their own, empty keychain entry; `apiKey` skips the keychain entirely.
    init(settings: AppSettings, session: URLSession = .shared, keychainAccount: String = IntervalsClient.keychainAccount, apiKey: String? = nil) {
        self.settings = settings
        self.session = session
        self.keychainAccount = keychainAccount
        self.apiKey = apiKey ?? KeychainStore.read(account: keychainAccount) ?? ""
    }

    var isConfigured: Bool { !apiKey.isEmpty }

    func setAPIKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        KeychainStore.save(trimmed, account: keychainAccount)
        apiKey = trimmed
    }

    /// FTP to use for targets: intervals.icu value if enabled and available, else the manual setting.
    var effectiveFTP: Int {
        if settings.useIntervalsFTP, let ftp = athlete?.ftp, ftp > 0 { return ftp }
        return settings.ftp
    }

    var zones: PowerZones { athlete?.zones ?? .standard }

    private var athleteId: String {
        let id = settings.intervalsAthleteId.trimmingCharacters(in: .whitespaces)
        return id.isEmpty ? "0" : id
    }

    func refreshAll() async {
        guard isConfigured else {
            state = .idle
            return
        }
        state = .loading
        do {
            try await fetchAthlete()
            try await fetchUpcoming()
            try? await fetchLibrary()
            state = .loaded
            lastRefresh = Date()
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Reloads planned workouts if the last refresh is older than `maxAge`.
    func refreshIfStale(maxAge: TimeInterval = 300) async {
        guard isConfigured, state != .loading else { return }
        if let lastRefresh, Date().timeIntervalSince(lastRefresh) < maxAge { return }
        await refreshAll()
    }

    func fetchAthlete() async throws {
        let data = try await get(path: "")
        athlete = try IntervalsAthlete.parse(data)
    }

    func fetchUpcoming() async throws {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let end = calendar.date(byAdding: .day, value: 7, to: today) ?? today
        let query = [
            URLQueryItem(name: "oldest", value: Self.day(today)),
            URLQueryItem(name: "newest", value: Self.day(end)),
            URLQueryItem(name: "category", value: "WORKOUT"),
            URLQueryItem(name: "resolve", value: "true"),
        ]
        let data = try await get(path: "events", query: query)
        upcoming = try IntervalsWorkoutParser.parseEvents(data, fallbackFTP: Double(effectiveFTP))
            .sorted { ($0.date ?? .distantFuture) < ($1.date ?? .distantFuture) }
    }

    func fetchLibrary() async throws {
        let data = try await get(path: "workouts")
        library = try IntervalsWorkoutParser.parseLibrary(data, fallbackFTP: Double(effectiveFTP))
    }

    /// Uploads a FIT file as a new activity. Returns the activity id.
    func upload(fit: Data, filename: String, name: String, description: String?, pairedEventId: Int?) async throws -> String {
        guard isConfigured else { throw IntervalsError.notConfigured }
        var components = URLComponents(url: Self.url(athleteId: athleteId, path: "activities"), resolvingAgainstBaseURL: false)!
        var items = [URLQueryItem(name: "name", value: name)]
        if let description { items.append(URLQueryItem(name: "description", value: description)) }
        if let pairedEventId { items.append(URLQueryItem(name: "paired_event_id", value: String(pairedEventId))) }
        components.queryItems = items
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        let boundary = "BikeApp-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var body = Data()
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n".utf8))
        body.append(Data("Content-Type: application/octet-stream\r\n\r\n".utf8))
        body.append(fit)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        let (data, response) = try await session.upload(for: request, from: body)
        try check(response, data)
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let id = json["id"] {
            return "\(id)"
        }
        return ""
    }

    // MARK: - FTP

    /// Writes a new FTP into the cycling sport settings.
    /// Updates the indoor FTP if one is set there, otherwise the FTP. Returns the change for undo.
    func updateFTP(_ watts: Int) async throws -> FTPChange {
        guard isConfigured else { throw IntervalsError.notConfigured }
        let data = try await get(path: "")
        guard let ride = IntervalsAthlete.rideSettings(data) else { throw IntervalsError.noRideSettings }
        let field = ride.indoorFTP != nil ? "indoor_ftp" : "ftp"
        let previous = field == "indoor_ftp" ? ride.indoorFTP : ride.ftp
        try await put(path: "sport-settings/\(ride.id)", json: [field: watts])
        try? await fetchAthlete()
        return FTPChange(settingsId: ride.id, field: field, previous: previous, new: watts)
    }

    /// Puts the previous value back.
    func restoreFTP(_ change: FTPChange) async throws {
        let value: Any = change.previous.map { $0 as Any } ?? NSNull()
        try await put(path: "sport-settings/\(change.settingsId)", json: [change.field: value])
        try? await fetchAthlete()
    }

    private func put(path: String, json: [String: Any]) async throws {
        guard isConfigured else { throw IntervalsError.notConfigured }
        var request = URLRequest(url: Self.url(athleteId: athleteId, path: path))
        request.httpMethod = "PUT"
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: json)
        let (data, response) = try await session.data(for: request)
        try check(response, data)
    }

    // MARK: - HTTP

    /// API URL without trailing slash, e.g. …/athlete/0 or …/athlete/0/events.
    static func url(athleteId: String, path: String) -> URL {
        let id = athleteId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "0"
        let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return URL(string: "https://intervals.icu/api/v1/athlete/\(id)" + (trimmed.isEmpty ? "" : "/\(trimmed)"))!
    }

    private var authorization: String {
        "Basic " + Data("API_KEY:\(apiKey)".utf8).base64EncodedString()
    }

    private func get(path: String, query: [URLQueryItem] = []) async throws -> Data {
        guard isConfigured else { throw IntervalsError.notConfigured }
        var components = URLComponents(url: Self.url(athleteId: athleteId, path: path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!)
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        try check(response, data)
        return data
    }

    private func check(_ response: URLResponse, _ data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw IntervalsError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw IntervalsError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
    }

    private static func day(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
