import XCTest
@testable import BikeApp

/// Click combinations, goal changes, ride storage and sync, Spotify output, URLs.
@MainActor
final class ControlsAndSyncTests: XCTestCase {
    // MARK: Click buttons

    func testSinglePressShiftsAndRepeats() {
        var c = ClickButtonInterpreter()
        XCTAssertEqual(c.process(.init(plus: true, minus: false)), [.shift(.up), .startRepeat(.up)])
        XCTAssertTrue(c.isHeld(.up))
        XCTAssertEqual(c.process(.init(plus: false, minus: false)), [.stopRepeat])
        XCTAssertEqual(c.process(.init(plus: false, minus: true)), [.shift(.down), .startRepeat(.down)])
    }

    func testBothButtonsPauseAndUndoTheFirstShift() {
        var c = ClickButtonInterpreter()
        _ = c.process(.init(plus: true, minus: false)) // shifts up
        XCTAssertEqual(c.process(.init(plus: true, minus: true)), [.stopRepeat, .shift(.down), .bothPressed])
        XCTAssertFalse(c.isHeld(.up), "no repeat during the combination")
        // Releasing one after the other does nothing.
        XCTAssertEqual(c.process(.init(plus: false, minus: true)), [])
        XCTAssertEqual(c.process(.init(plus: false, minus: false)), [])
        // Afterwards single presses work again.
        XCTAssertEqual(c.process(.init(plus: true, minus: false)), [.shift(.up), .startRepeat(.up)])
    }

    func testBothButtonsAtOnce() {
        var c = ClickButtonInterpreter()
        XCTAssertEqual(c.process(.init(plus: true, minus: true)), [.stopRepeat, .bothPressed])
    }

    // MARK: Goal changes

    private func makeModel(rides: URL? = nil) -> AppModel {
        let suite = "BikeAppControlsTests"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let settings = AppSettings(defaults: defaults)
        settings.autoUpload = false
        let directory = rides ?? FileManager.default.temporaryDirectory.appendingPathComponent("BikeAppTests-\(UUID().uuidString)")
        return AppModel(
            settings: settings,
            rides: RideStore(directory: directory),
            intervals: IntervalsClient(settings: settings, keychainAccount: "test-\(UUID().uuidString)")
        )
    }

    private func freeRide(_ model: AppModel, goal: SessionGoal) -> RideEngine {
        let config = SessionConfig(name: "Test", courseTitle: "", gradeRange: GradeRange(min: -5, max: 7), seed: 9, goal: goal, workout: nil, workoutMode: .ergOffset, presetTitle: "Hügelig")
        return RideEngine(config: config, settings: model.settings, ble: model.ble) { 250 }
    }

    func testAdjustDistanceGoal() {
        let model = makeModel()
        let engine = freeRide(model, goal: .distance(meters: 30_000))
        engine.applyPreview(distance: 12_400, movingTime: 2500, power: 200, cadence: 85, heartRate: nil, gear: 12)
        engine.adjustGoal(by: 1)
        XCTAssertEqual(engine.config.goal, .distance(meters: 35_000))
        XCTAssertEqual(engine.barColumns.count, 110)
        XCTAssertEqual(engine.barMarker, 12_400 / 35_000, accuracy: 1e-9)
        // Shortening below the current position stops just ahead of the rider.
        engine.setGoal(.distance(meters: 5000))
        XCTAssertEqual(engine.config.goal, .distance(meters: 13_000))
        XCTAssertEqual(engine.config.goal.label, "13,0 km")
    }

    func testSwitchToDurationGoal() {
        let model = makeModel()
        let engine = freeRide(model, goal: .distance(meters: 30_000))
        engine.applyPreview(distance: 8000, movingTime: 1210, power: 200, cadence: 85, heartRate: nil, gear: 12)
        engine.setGoal(.duration(seconds: 3600))
        XCTAssertEqual(engine.config.goal, .duration(seconds: 3600))
        XCTAssertEqual(engine.remainingTime ?? 0, 2390, accuracy: 1e-9)
        engine.adjustGoal(by: -1)
        XCTAssertEqual(engine.config.goal, .duration(seconds: 3300))
        engine.setGoal(.duration(seconds: 60))
        XCTAssertEqual(engine.config.goal, .duration(seconds: 1320), "rounded up to whole minutes ahead of the rider")
        XCTAssertEqual(engine.barMarker, 0.2, accuracy: 1e-9, "rolling profile window")
    }

    func testWorkoutGoalCannotChange() {
        let model = makeModel()
        let workout = Workout(id: "w", name: "W", date: nil, eventId: nil, description: nil, steps: [.steady(600, 0.8)])
        let config = SessionConfig(name: "W", courseTitle: "", gradeRange: GradeRange(min: 0, max: 2), seed: 1, goal: .workout, workout: workout, workoutMode: .ergOffset)
        let engine = RideEngine(config: config, settings: model.settings, ble: model.ble) { 250 }
        XCTAssertFalse(engine.canChangeGoal)
        engine.adjustGoal(by: 1)
        XCTAssertEqual(engine.config.goal, .workout)
    }

    // MARK: Ride storage

    func testFinishedRideIsSavedAndWaitsForKey() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("BikeAppTests-\(UUID().uuidString)")
        let model = makeModel(rides: directory)
        model.ble.startTemporaryDemo()
        model.startRide(SessionConfig(name: "Sync", courseTitle: "", gradeRange: GradeRange(min: -3, max: 4), seed: 3, goal: .duration(seconds: 2.5), workout: nil, workoutMode: .ergOffset, presetTitle: "Wellig"))
        RunLoop.main.run(until: Date().addingTimeInterval(4))

        let ride = try? XCTUnwrap(model.finished)
        XCTAssertEqual(ride?.uploadState, .waitingForKey)
        XCTAssertTrue(ride?.name.hasPrefix("Bike App – Wellig · ") ?? false)

        // A new store on the same folder (= next app start) still has the ride, not uploaded yet.
        let reopened = RideStore(directory: directory)
        XCTAssertEqual(reopened.pending.count, 1)
        XCTAssertEqual(reopened.pending.first?.id, ride?.filename)
        XCTAssertEqual(reopened.fit(for: ride?.filename ?? ""), ride?.fit)
        XCTAssertEqual(model.pendingUploads, 1)
        try? FileManager.default.removeItem(at: directory)
    }

    static func syntheticRide(seconds: Int = 600, start: Date = Date(timeIntervalSince1970: 1_794_500_000)) -> (samples: [RideSample], summary: RideSummary, fit: Data) {
        var samples: [RideSample] = []
        var distance = 0.0
        for i in 0..<seconds {
            let power = i < seconds / 2 ? 180 : 260
            distance += 8
            samples.append(RideSample(timestamp: start.addingTimeInterval(Double(i + 1)), elapsed: Double(i + 1), power: power, cadence: 88,
                                      heartRate: 120 + i / 20, speed: 8, distance: distance, altitude: 240 + sin(Double(i) / 60) * 20, gradePercent: 0))
        }
        let summary = RideSummary.compute(samples: samples[...], startTime: start, endTime: start.addingTimeInterval(Double(seconds + 1)))
        return (samples, summary, ActivityFITBuilder.build(samples: samples, laps: [], summary: summary))
    }

    func testStoreUpdatesImportAndDelete() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("BikeAppTests-\(UUID().uuidString)")
        let store = RideStore(directory: directory)
        let ride = Self.syntheticRide()
        store.save(fit: ride.fit, entry: .make(id: "a.fit", name: "A", subtitle: "Hügelig", description: nil, pairedEventId: 7,
                                                samples: ride.samples, summary: ride.summary, ftp: 250, zones: .standard))
        XCTAssertEqual(store.pending.map(\.id), ["a.fit"])
        let saved = try XCTUnwrap(store.entry(id: "a.fit"))
        XCTAssertEqual(saved.summary?.avgPower, 220)
        XCTAssertLessThanOrEqual(saved.series?.power.count ?? 999, 360)
        XCTAssertEqual(saved.zoneSeconds?.reduce(0, +) ?? 0, 600, accuracy: 0.1)
        XCTAssertEqual(saved.zoneSeconds?[1] ?? 0, 300, accuracy: 0.1) // 180 W = 72 % FTP → Z2
        XCTAssertEqual(saved.zoneSeconds?[3] ?? 0, 300, accuracy: 0.1) // 260 W = 104 % FTP → Z4
        store.update("a.fit") { $0.uploadedActivityId = "i123" }
        XCTAssertTrue(store.pending.isEmpty)
        XCTAssertEqual(store.entry(id: "a.fit")?.pairedEventId, 7)

        // Import of a FIT file reads figures and curves from the file.
        let file = directory.appendingPathComponent("import-source.fit")
        try ride.fit.write(to: file)
        let imported = try store.importFIT(from: file, ftp: 250, zones: .standard)
        XCTAssertEqual(store.pending.map(\.id), [imported.id])
        XCTAssertEqual(imported.distance, 4800, accuracy: 1)
        XCTAssertEqual(imported.summary?.avgPower, 220)
        XCTAssertEqual(imported.summary?.avgHeartRate, ride.summary.avgHeartRate)
        XCTAssertEqual(imported.movingTime, 600, accuracy: 0.5)
        XCTAssertEqual(imported.name, "Bike App – 4,8 km")

        let notFIT = directory.appendingPathComponent("kaputt.fit")
        try Data("hallo".utf8).write(to: notFIT)
        XCTAssertThrowsError(try store.importFIT(from: notFIT, ftp: 250, zones: .standard))
        try FileManager.default.removeItem(at: notFIT)

        // A FIT file dropped into the folder by hand gets an entry.
        try ride.fit.write(to: directory.appendingPathComponent("lose.fit"))
        store.adoptLooseFiles(ftp: 250, zones: .standard)
        XCTAssertNotNil(store.entry(id: "lose.fit")?.series)

        store.delete(id: "a.fit")
        XCTAssertNil(store.entry(id: "a.fit"))
        XCTAssertNil(store.fit(for: "a.fit"))
        try? FileManager.default.removeItem(at: directory)
    }

    func testFITRoundTrip() throws {
        let ride = Self.syntheticRide(seconds: 120)
        let decoded = try FITDecoder.ride(from: ride.fit)
        XCTAssertEqual(decoded.samples.count, 120)
        XCTAssertEqual(decoded.movingTime ?? 0, 120, accuracy: 0.01)
        for (a, b) in zip(decoded.samples, ride.samples) {
            XCTAssertEqual(a.power, b.power)
            XCTAssertEqual(a.heartRate, b.heartRate)
            XCTAssertEqual(a.cadence, b.cadence)
            XCTAssertEqual(a.distance, b.distance, accuracy: 0.01)
            XCTAssertEqual(a.altitude, b.altitude, accuracy: 0.2)
            XCTAssertEqual(a.speed, b.speed, accuracy: 0.001)
            XCTAssertEqual(a.timestamp.timeIntervalSince1970, b.timestamp.timeIntervalSince1970.rounded(.down), accuracy: 1)
        }
        XCTAssertThrowsError(try FITDecoder.ride(from: Data("keine fit".utf8)))
    }

    func testWeekOverview() {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = .current
        let now = Date()
        let today = RideStore.Entry(id: "t", name: "T", date: now, distance: 30_000, movingTime: 3600)
        let lastWeek = RideStore.Entry(id: "l", name: "L", date: calendar.date(byAdding: .day, value: -7, to: now)!, distance: 20_000, movingTime: 1800)
        let weeks = WeekOverview.weeks([today, lastWeek], now: now)
        XCTAssertEqual(weeks.count, 8)
        XCTAssertEqual(weeks.last?.hours ?? 0, 1, accuracy: 1e-9)
        XCTAssertEqual(weeks[weeks.count - 2].hours, 0.5, accuracy: 1e-9)
        XCTAssertEqual(weeks.last?.km ?? 0, 30, accuracy: 1e-9)
    }

    // MARK: Spotify and URLs

    func testSpotifyOutputParsing() {
        let playing = SpotifyController.parse("playing\nTitel\nKünstlerin\nspotify:track:123\nhttps://i.scdn.co/image/abc\n")
        XCTAssertEqual(playing?.isPlaying, true)
        XCTAssertEqual(playing?.track?.name, "Titel")
        XCTAssertEqual(playing?.track?.artist, "Künstlerin")
        XCTAssertEqual(playing?.track?.id, "spotify:track:123")
        XCTAssertEqual(playing?.track?.artworkURL?.absoluteString, "https://i.scdn.co/image/abc")
        XCTAssertEqual(SpotifyController.parse("paused\nA\nB\nid\n")?.isPlaying, false)
        XCTAssertEqual(SpotifyController.parse("notrunning\n")?.isRunning, false)
        XCTAssertNil(SpotifyController.parse("stopped\n")?.track)
        XCTAssertNil(SpotifyController.parse("Fehler"))
    }

    func testIntervalsURLsHaveNoTrailingSlash() {
        XCTAssertEqual(IntervalsClient.url(athleteId: "0", path: "").absoluteString, "https://intervals.icu/api/v1/athlete/0")
        XCTAssertEqual(IntervalsClient.url(athleteId: "i123", path: "events").absoluteString, "https://intervals.icu/api/v1/athlete/i123/events")
        XCTAssertEqual(IntervalsClient.url(athleteId: "0", path: "/workouts").absoluteString, "https://intervals.icu/api/v1/athlete/0/workouts")
    }
}
