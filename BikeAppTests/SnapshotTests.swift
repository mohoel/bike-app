import SwiftUI
import XCTest
@testable import BikeApp

/// Renders the bar and the full screen view to PNG files for a visual check.
/// Output folder: $BIKEAPP_SNAPSHOT_DIR (pass TEST_RUNNER_BIKEAPP_SNAPSHOT_DIR to xcodebuild) or the temp folder.
@MainActor
final class SnapshotTests: XCTestCase {
    private var outputDirectory: URL {
        if let path = ProcessInfo.processInfo.environment["BIKEAPP_SNAPSHOT_DIR"], !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.temporaryDirectory.appendingPathComponent("BikeAppSnapshots", isDirectory: true)
    }

    private func makeModel() -> AppModel {
        AppModel.isolated(suite: "BikeAppSnapshotTests")
    }

    private static let sweetSpot = Workout(id: "ss", name: "Sweet Spot 3 × 10 min", date: nil, eventId: nil, description: nil, steps: [
        .steady(240, 0.5), .steady(180, 0.65), .steady(180, 0.8),
        .steady(600, 0.92), .steady(300, 0.56), .steady(600, 0.92),
        .steady(300, 0.56), .steady(600, 0.92), .ramp(600, from: 0.55, to: 0.4),
    ])

    private func rideEngine(_ model: AppModel, workout: Workout? = nil, mode: WorkoutMode = .ergOffset, phase: RideEngine.Phase = .riding) -> RideEngine {
        let config = SessionConfig(
            name: workout?.name ?? "Bike App – Bergig 30 km",
            courseTitle: "Bergig · −6 … +10 %",
            gradeRange: GradeRange(min: -6, max: 10),
            seed: 502,
            goal: workout == nil ? .distance(meters: 30_000) : .workout,
            workout: workout,
            workoutMode: mode
        )
        let engine = RideEngine(config: config, settings: model.settings, ble: model.ble) { 250 }
        if workout == nil {
            engine.applyPreview(distance: 12_400, movingTime: 2530, power: 245, cadence: 84, heartRate: 151, gear: 9, phase: phase)
        } else {
            engine.applyPreview(distance: 18_300, movingTime: 1966, power: 228, cadence: 91, heartRate: 158, gear: 12, phase: phase)
        }
        return engine
    }

    private func render<V: View>(_ view: V, name: String, scale: CGFloat = 2) throws {
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            return XCTFail("could not render \(name)")
        }
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let url = outputDirectory.appendingPathComponent("\(name).png")
        try png.write(to: url)
        print("Snapshot: \(url.path)")
    }

    private func barOnBackdrop(_ display: RideDisplay, s: CGFloat = 1) -> some View {
        OverlayBar(display: display, s: s, opacity: 0.72, useMaterial: false, showsGrip: false)
            .padding(24)
            .background(Theme.backdrop)
    }

    func testRenderBarStates() throws {
        let model = makeModel()
        let ride = rideEngine(model)
        try render(barOnBackdrop(RideDisplay(engine: ride, ftp: 250, zones: .standard)), name: "bar-ride")
        try render(barOnBackdrop(RideDisplay(engine: ride, ftp: 250, zones: .standard), s: 0.7), name: "bar-ride-small")

        let workout = rideEngine(model, workout: Self.sweetSpot)
        try render(barOnBackdrop(RideDisplay(engine: workout, ftp: 250, zones: .standard)), name: "bar-workout")

        let paused = rideEngine(model, phase: .paused)
        try render(barOnBackdrop(RideDisplay(engine: paused, ftp: 250, zones: .standard)), name: "bar-paused")
    }

    func testRenderFTPTest() throws {
        let model = makeModel()
        let plan = FTPTestPlan.make(.ramp, ftp: 250, baseIsKnown: false)
        let config = SessionConfig(name: plan.workout.name, courseTitle: plan.kind.title, gradeRange: GradeRange(min: 0, max: 0), seed: 1,
                                   goal: .workout, workout: plan.workout, workoutMode: .ergGears, presetTitle: "FTP-Test", test: plan)
        let engine = RideEngine(config: config, settings: model.settings, ble: model.ble) { 250 }
        engine.applyPreview(distance: 6200, movingTime: 300 + 8 * 60 + 22, power: 248, cadence: 92, heartRate: 168, gear: 12)
        try render(barOnBackdrop(RideDisplay(engine: engine, ftp: 250, zones: .standard)), name: "bar-ftp-ramp")
        try render(
            FullscreenRide(display: RideDisplay(engine: engine, ftp: 250, zones: .standard), s: 1)
                .frame(width: 1440, height: 900)
                .background(Theme.background)
                .environment(model),
            name: "fullscreen-ftp-ramp", scale: 1
        )
        let outcome = FTPTestOutcome(result: FTPTestResult(kind: .ramp, ftp: 218, basis: 290, effortSeconds: 726, completed: true, plausible: true, reason: nil), previousAppFTP: 250)
        outcome.applied = true
        outcome.transfer = .transferred(FTPChange(settingsId: 3015373, field: "ftp", previous: nil, new: 218))
        try render(
            FTPResultCard(outcome: outcome)
                .padding(28)
                .frame(width: 1000)
                .background(Theme.background)
                .environment(\.colorScheme, .dark)
                .environment(model),
            name: "ftp-result"
        )
    }

    func testRenderHistory() throws {
        let model = makeModel()
        // Three sample rides on different days.
        let day: TimeInterval = 86_400
        let base = Date().addingTimeInterval(-2 * day)
        for (k, seconds) in [3700, 2400, 4500].enumerated() {
            let start = base.addingTimeInterval(Double(k) * -3 * day)
            var samples: [RideSample] = []
            var distance = 0.0
            var rng = SplitMix64(seed: UInt64(k + 1))
            for i in 0..<seconds {
                let wave = sin(Double(i) / 240) * 60 + sin(Double(i) / 37) * 25
                let power = Swift.max(0, Int(200 + wave + (rng.unit() - 0.5) * 30))
                distance += 8.5 + wave / 40
                samples.append(RideSample(timestamp: start.addingTimeInterval(Double(i)), elapsed: Double(i), power: power, cadence: 88,
                                          heartRate: 125 + Int(wave / 3) + i / 200, speed: 8.5, distance: distance,
                                          altitude: 240 + sin(Double(i) / 400) * 60 + Double(i) / 120, gradePercent: 0))
            }
            let summary = RideSummary.compute(samples: samples[...], startTime: start, endTime: start.addingTimeInterval(Double(seconds)))
            let id = "BikeApp-snapshot-\(k).fit"
            var entry = RideStore.Entry.make(id: id, name: ["Bike App – Hügelig · 30,2 km", "Sweet Spot 3 × 10 min", "Bike App – Bergig · 38,4 km"][k],
                                             subtitle: "Hügelig · −5 … +7 %", description: nil, pairedEventId: nil,
                                             samples: samples, summary: summary, ftp: 250, zones: .standard)
            if k > 0 { entry.uploadedActivityId = "i\(100 + k)" }
            model.rides.save(fit: ActivityFITBuilder.build(samples: samples, laps: [], summary: summary), entry: entry)
        }
        model.reloadHistory()
        XCTAssertEqual(model.history.count, 3)

        try render(
            VStack(alignment: .leading, spacing: 18) {
                WeekOverview(entries: model.history)
                VStack(spacing: 10) {
                    ForEach(model.history) { entry in
                        RideRow(entry: entry, ftp: 250, zones: .standard, configured: false) {}
                    }
                }
            }
            .padding(28)
            .frame(width: 1000)
            .background(Theme.background)
            .environment(\.colorScheme, .dark)
            .environment(model),
            name: "history-list"
        )
        try render(
            RideDetailContent(entry: model.history[0], zones: .standard, fallbackFTP: 250)
                .padding(28)
                .frame(width: 1000)
                .background(Theme.background)
                .environment(\.colorScheme, .dark),
            name: "history-detail"
        )
    }

    func testRenderBarWithControlRow() throws {
        let model = makeModel()
        model.spotify.applyPreview(name: "Titel des Songs", artist: "Künstlerin", playing: true)
        let ride = rideEngine(model)
        try render(
            OverlayBar(display: RideDisplay(engine: ride, ftp: 250, zones: .standard), s: 1, opacity: 0.72, useMaterial: false, showsGrip: false, controls: true)
                .padding(24)
                .background(Theme.backdrop)
                .environment(model),
            name: "bar-controls"
        )
        let paused = rideEngine(model, phase: .paused)
        try render(
            OverlayBar(display: RideDisplay(engine: paused, ftp: 250, zones: .standard), s: 0.75, opacity: 0.72, useMaterial: false, showsGrip: false, controls: true)
                .padding(24)
                .background(Theme.backdrop)
                .environment(model),
            name: "bar-controls-paused-small"
        )
    }

    func testRenderFullscreen() throws {
        let model = makeModel()
        let ride = rideEngine(model)
        try render(
            FullscreenRide(display: RideDisplay(engine: ride, ftp: 250, zones: .standard), s: 1)
                .frame(width: 1440, height: 900)
                .background(Theme.background)
                .environment(model),
            name: "fullscreen-ride", scale: 1
        )
        let workout = rideEngine(model, workout: Self.sweetSpot)
        try render(
            FullscreenRide(display: RideDisplay(engine: workout, ftp: 250, zones: .standard), s: 1)
                .frame(width: 1440, height: 900)
                .background(Theme.background)
                .environment(model),
            name: "fullscreen-workout", scale: 1
        )
    }
}
