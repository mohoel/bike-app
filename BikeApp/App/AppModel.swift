import Foundation
import Observation

@MainActor
protocol RideUICoordinator: AnyObject {
    func rideDidStart()
    func rideDidFinish()
    func displayModeChanged()
    func overlayStateChanged()
}

/// A finished ride. It is already saved on disk; this tracks its upload.
@Observable @MainActor
final class FinishedRide {
    enum UploadState: Equatable {
        case idle
        /// Saved; uploads automatically once an API key is set.
        case waitingForKey
        case uploading
        case uploaded(String)
        /// Upload failed; retried later automatically.
        case queued(String)
        case failed(String)
    }

    let summary: RideSummary
    let fit: Data
    let name: String
    let filename: String
    let pairedEventId: Int?
    var uploadState: UploadState = .idle

    init(summary: RideSummary, fit: Data, name: String, filename: String, pairedEventId: Int?) {
        self.summary = summary
        self.fit = fit
        self.name = name
        self.filename = filename
        self.pairedEventId = pairedEventId
    }
}

/// Result of an FTP test and its way into the app and intervals.icu.
@Observable @MainActor
final class FTPTestOutcome {
    enum Transfer: Equatable {
        case idle
        /// Saved in the app; sent once an API key is set.
        case waitingForKey
        case sending
        case transferred(FTPChange)
        case undone
        case failed(String)
        /// Not applied automatically (implausible); the rider can confirm it.
        case needsConfirmation(String)
    }

    let result: FTPTestResult
    let previousAppFTP: Int
    var applied = false
    var transfer: Transfer = .idle

    init(result: FTPTestResult, previousAppFTP: Int) {
        self.result = result
        self.previousAppFTP = previousAppFTP
    }
}

/// Root state of the app.
@Observable @MainActor
final class AppModel {
    let settings: AppSettings
    let ble: BLEManager
    let intervals: IntervalsClient
    let spotify = SpotifyController()
    @ObservationIgnored let rides: RideStore
    /// Workouts built in the app.
    let customWorkouts: CustomWorkoutStore

    private(set) var engine: RideEngine?
    var finished: FinishedRide?
    private(set) var displayMode: DisplayMode
    private(set) var overlayVisible = true
    private(set) var clickThrough = false
    /// Rides saved on disk that are not on intervals.icu yet.
    private(set) var pendingUploads = 0
    /// All saved rides, newest first.
    private(set) var history: [RideStore.Entry] = []
    /// Result of the last FTP test (shown during the cooldown and in the summary).
    private(set) var ftpOutcome: FTPTestOutcome?

    @ObservationIgnored weak var coordinator: RideUICoordinator?
    @ObservationIgnored var openMainWindow: (() -> Void)?

    init(settings: AppSettings = AppSettings(), rides: RideStore? = nil, intervals: IntervalsClient? = nil, customWorkouts: CustomWorkoutStore? = nil) {
        self.settings = settings
        self.customWorkouts = customWorkouts ?? CustomWorkoutStore()
        ble = BLEManager(settings: settings)
        self.intervals = intervals ?? IntervalsClient(settings: settings)
        self.rides = rides ?? RideStore()
        displayMode = settings.defaultDisplay
    }

    /// Model for tests and previews: own settings, temporary ride folder, empty API key.
    static func isolated(suite: String) -> AppModel {
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let settings = AppSettings(defaults: defaults)
        settings.autoUpload = false
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("BikeApp-\(suite)-\(UUID().uuidString)", isDirectory: true)
        return AppModel(
            settings: settings,
            rides: RideStore(directory: directory),
            intervals: IntervalsClient(settings: settings, keychainAccount: "isolated-\(UUID().uuidString)"),
            customWorkouts: CustomWorkoutStore(directory: directory)
        )
    }

    func bootstrap() {
        ble.onShift = { [weak self] direction in self?.shift(direction) }
        ble.onBothButtons = { [weak self] in self?.togglePause() }
        ble.onTrainerReady = { [weak self] in self?.engine?.resendResistance() }
        ble.start()
        rides.adoptLooseFiles(ftp: intervals.effectiveFTP, zones: intervals.zones)
        rides.completeDetails(ftp: intervals.effectiveFTP, zones: intervals.zones)
        reloadHistory()
        Task {
            await intervals.refreshAll()
            await syncPending()
        }
    }

    func reloadHistory() {
        history = rides.entries()
        pendingUploads = history.filter { !$0.isUploaded }.count
    }

    /// Called when the app comes to the front: refresh workouts and upload waiting rides.
    func appDidBecomeActive() {
        Task {
            await intervals.refreshIfStale()
            await syncPending()
        }
    }

    var isRiding: Bool {
        guard let engine else { return false }
        return engine.phase != .finished
    }

    // MARK: Session

    func startRide(_ config: SessionConfig) {
        engine?.finish()
        finished = nil
        ftpOutcome = nil
        let engine = RideEngine(config: config, settings: settings, ble: ble) { [weak self] in
            self?.intervals.effectiveFTP ?? 250
        }
        engine.onFinish = { [weak self] engine in self?.rideFinished(engine) }
        engine.onTestResult = { [weak self] result in self?.handleTestResult(result) }
        self.engine = engine
        displayMode = settings.defaultDisplay
        overlayVisible = true
        engine.start()
        if settings.showControlRow { spotify.start() }
        coordinator?.rideDidStart()
    }

    func stopRide() {
        engine?.finish()
    }

    func discardRide() {
        engine = nil
        finished = nil
    }

    func togglePause() {
        // During the ramp both Click buttons (or ⌃⌥P) mean "I'm done", pausing would spoil the test.
        if let engine, engine.canEndTestEffort {
            engine.endTestEffort()
            return
        }
        engine?.togglePause()
    }

    func endTestEffort() {
        engine?.endTestEffort()
    }

    /// Builds the FTP test for the current FTP.
    func makeTestPlan(_ kind: FTPTestKind) -> FTPTestPlan {
        let known = settings.useIntervalsFTP && intervals.athlete?.ftp != nil
        return FTPTestPlan.make(kind, ftp: intervals.effectiveFTP, baseIsKnown: known)
    }

    // MARK: FTP test result

    func handleTestResult(_ result: FTPTestResult) {
        let outcome = FTPTestOutcome(result: result, previousAppFTP: settings.ftp)
        ftpOutcome = outcome
        guard result.plausible else {
            outcome.transfer = .needsConfirmation(result.reason ?? "Das Ergebnis ist unsicher.")
            return
        }
        applyFTP(outcome, transfer: settings.autoTransferFTP)
    }

    /// Takes the test result as the new FTP in the app and optionally sends it to intervals.icu.
    func applyFTP(_ outcome: FTPTestOutcome, transfer: Bool) {
        settings.ftp = outcome.result.ftp
        outcome.applied = true
        if transfer {
            transferFTP(outcome)
        } else {
            outcome.transfer = .idle
        }
    }

    func transferFTP(_ outcome: FTPTestOutcome) {
        let ftp = outcome.result.ftp
        guard intervals.isConfigured else {
            settings.pendingFTPTransfer = ftp
            outcome.transfer = .waitingForKey
            return
        }
        outcome.transfer = .sending
        Task {
            do {
                let change = try await intervals.updateFTP(ftp)
                settings.pendingFTPTransfer = 0
                outcome.transfer = .transferred(change)
            } catch {
                settings.pendingFTPTransfer = ftp
                outcome.transfer = .failed(error.localizedDescription)
            }
        }
    }

    /// Puts back the FTP from before the test (app and intervals.icu).
    func undoFTP(_ outcome: FTPTestOutcome) {
        settings.ftp = outcome.previousAppFTP
        outcome.applied = false
        if settings.pendingFTPTransfer == outcome.result.ftp { settings.pendingFTPTransfer = 0 }
        guard case let .transferred(change) = outcome.transfer else {
            outcome.transfer = .undone
            return
        }
        outcome.transfer = .sending
        Task {
            do {
                try await intervals.restoreFTP(change)
                outcome.transfer = .undone
            } catch {
                outcome.transfer = .failed("Rückgängig fehlgeschlagen: \(error.localizedDescription)")
            }
        }
    }

    /// Sends a test result that waited for the API key.
    private func transferPendingFTP() async {
        let ftp = settings.pendingFTPTransfer
        guard ftp > 0, intervals.isConfigured else { return }
        do {
            let change = try await intervals.updateFTP(ftp)
            settings.pendingFTPTransfer = 0
            if let outcome = ftpOutcome, outcome.result.ftp == ftp { outcome.transfer = .transferred(change) }
        } catch {
            if let outcome = ftpOutcome, outcome.result.ftp == ftp { outcome.transfer = .failed(error.localizedDescription) }
        }
    }

    func shift(_ direction: ShiftDirection) {
        engine?.shift(direction)
    }

    func adjustGoal(by steps: Int) {
        engine?.adjustGoal(by: steps)
    }

    func setGoal(_ goal: SessionGoal) {
        engine?.setGoal(goal)
    }

    private func activityName(for engine: RideEngine, summary: RideSummary) -> String {
        if let plan = engine.config.test {
            if let result = engine.testResult { return "Bike App – FTP-Test (\(plan.kind.shortTitle)) · FTP \(result.ftp) W" }
            return "Bike App – FTP-Test (\(plan.kind.shortTitle))"
        }
        if engine.config.workout != nil { return engine.config.name }
        let preset = engine.config.presetTitle.isEmpty ? "Freie Fahrt" : engine.config.presetTitle
        return "Bike App – \(preset) · \(Fmt.km(summary.distance)) km"
    }

    private func rideFinished(_ engine: RideEngine) {
        let samples = engine.recorder.samples
        coordinator?.rideDidFinish()
        spotify.stop()
        guard !samples.isEmpty else {
            self.engine = nil
            return
        }
        let end = engine.endDate ?? Date()
        let summary = RideSummary.compute(samples: samples[...], startTime: engine.startDate, endTime: end)
        let fit = ActivityFITBuilder.build(samples: samples, laps: engine.recorder.laps, summary: summary)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let filename = "BikeApp-\(formatter.string(from: engine.startDate)).fit"
        let name = activityName(for: engine, summary: summary)
        var description = "Gefahren mit Bike App"
        if let result = engine.testResult {
            description = "FTP-Test mit Bike App: \(result.basisText) = FTP \(result.ftp) W"
        }
        let ride = FinishedRide(summary: summary, fit: fit, name: name, filename: filename, pairedEventId: engine.config.workout?.eventId)

        // Save first, so the ride survives missing key, missing network or quitting the app.
        let subtitle: String
        if let plan = engine.config.test {
            subtitle = "FTP-Test · \(plan.kind.title)" + (engine.testResult.map { " · Ergebnis \($0.ftp) W" } ?? "")
        } else if let workout = engine.config.workout {
            let source = workout.id.hasPrefix(CustomWorkout.idPrefix) ? "Eigenes Workout" : "intervals.icu-Workout"
            subtitle = "\(source) · \(engine.config.workoutMode.title)"
        } else {
            subtitle = engine.config.courseTitle
        }
        var entry = RideStore.Entry.make(
            id: filename, name: name, subtitle: subtitle, description: description, pairedEventId: ride.pairedEventId,
            samples: samples, summary: summary, ftp: engine.config.test?.baseFTP ?? intervals.effectiveFTP, zones: intervals.zones
        )
        entry.ftpTestResult = engine.testResult?.ftp
        rides.save(fit: fit, entry: entry)
        reloadHistory()
        finished = ride

        if !intervals.isConfigured {
            ride.uploadState = .waitingForKey
        } else if settings.autoUpload {
            upload(ride)
        }
    }

    func upload(_ ride: FinishedRide) {
        guard intervals.isConfigured else {
            ride.uploadState = .waitingForKey
            return
        }
        ride.uploadState = .uploading
        Task {
            do {
                let id = try await rides.upload(id: ride.filename, using: intervals)
                ride.uploadState = .uploaded(id)
            } catch {
                ride.uploadState = .queued(error.localizedDescription)
            }
            reloadHistory()
        }
    }

    /// Uploads one ride from the history.
    func uploadStored(_ id: String) async {
        guard intervals.isConfigured else { return }
        _ = try? await rides.upload(id: id, using: intervals)
        reloadHistory()
    }

    /// Deletes a ride from this Mac (intervals.icu keeps its copy).
    func deleteRide(_ id: String) {
        rides.delete(id: id)
        reloadHistory()
    }

    /// Uploads every saved ride that is not on intervals.icu yet.
    func syncPending() async {
        guard intervals.isConfigured else {
            reloadHistory()
            return
        }
        await rides.uploadPending(using: intervals)
        await transferPendingFTP()
        reloadHistory()
        // Keep the summary on screen in sync.
        if let ride = finished, let entry = rides.entry(id: ride.filename) {
            if let id = entry.uploadedActivityId {
                ride.uploadState = .uploaded(id == "ok" ? "" : id)
            } else if let error = entry.lastError {
                ride.uploadState = .queued(error)
            }
        }
    }

    /// Saves the API key, then loads workouts and uploads waiting rides.
    func saveAPIKey(_ key: String) async {
        intervals.setAPIKey(key)
        guard intervals.isConfigured else { return }
        await intervals.refreshAll()
        await syncPending()
    }

    func importFIT(from url: URL) async throws {
        _ = try rides.importFIT(from: url, ftp: intervals.effectiveFTP, zones: intervals.zones)
        reloadHistory()
        await syncPending()
    }

    // MARK: Display

    func setDisplayMode(_ mode: DisplayMode) {
        guard mode != displayMode else { return }
        displayMode = mode
        coordinator?.displayModeChanged()
    }

    func toggleDisplayMode() {
        setDisplayMode(displayMode == .bar ? .fullscreen : .bar)
    }

    func toggleOverlay() {
        overlayVisible.toggle()
        coordinator?.overlayStateChanged()
    }

    func toggleClickThrough() {
        clickThrough.toggle()
        coordinator?.overlayStateChanged()
    }
}
