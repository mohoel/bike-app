import XCTest
@testable import BikeApp

/// Serves canned responses for intervals.icu requests and records what was sent.
final class MockURLProtocol: URLProtocol {
    struct Recorded {
        var method: String
        var url: String
        var headers: [String: String]
        var body: Data?
    }

    static var handler: ((URLRequest) -> (Int, Data))?
    static var requests: [Recorded] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody
        if body == nil, let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                data.append(buffer, count: n)
            }
            stream.close()
            body = data
        }
        Self.requests.append(Recorded(method: request.httpMethod ?? "GET", url: request.url?.absoluteString ?? "", headers: request.allHTTPHeaderFields ?? [:], body: body))
        let (status, data) = Self.handler?(request) ?? (404, Data())
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@MainActor
final class FTPTestTests: XCTestCase {
    // MARK: Plans

    func testRampPlan() {
        let plan = FTPTestPlan.make(.ramp, ftp: 250, baseIsKnown: false)
        XCTAssertEqual(plan.effortStart, 300)
        XCTAssertEqual(plan.rampStep, 15)
        XCTAssertEqual(plan.rampWatts(at: 300), 125)
        XCTAssertEqual(plan.rampWatts(at: 365), 140)
        XCTAssertNil(plan.rampWatts(at: 100))
        // 125 W … 500 W in 15 W steps = 26 minutes of ramp, then the cooldown.
        XCTAssertEqual(plan.effortEnd, 300 + 26 * 60)
        XCTAssertEqual(plan.workout.steps.last?.label, "Ausfahren")
    }

    func testTwentyMinutePlan() {
        let plan = FTPTestPlan.make(.twenty, ftp: 250, baseIsKnown: true)
        XCTAssertEqual(plan.effortStart, 1560)
        XCTAssertEqual(plan.effortEnd, 2760)
        XCTAssertEqual(plan.workout.duration, 3360)
        let effort = WorkoutPlayer(workout: plan.workout).position(at: 1600)?.step
        XCTAssertEqual(effort?.kind, .free, "no ERG during the 20 minutes")
    }

    func testTruncatedRamp() {
        let plan = FTPTestPlan.make(.ramp, ftp: 250, baseIsKnown: false)
        let cut = FTPTestPlan.truncated(plan.workout, at: plan.effortStart + 90)
        XCTAssertEqual(cut.duration, 300 + 90 + 300)
        XCTAssertEqual(cut.steps.last, FTPTestPlan.cooldown)
        XCTAssertEqual(cut.steps[cut.steps.count - 2].duration, 30)
    }

    // MARK: Tracker

    func testRampEndsWhenTheRiderFails() {
        let plan = FTPTestPlan.make(.ramp, ftp: 250, baseIsKnown: false)
        var tracker = FTPTestTracker(plan: plan)
        var ended = false
        var t = 0.0
        while !ended, t < plan.effortEnd {
            let target = plan.rampWatts(at: t)
            // The rider holds every step up to 290 W and cracks at 305 W.
            let fails = (target ?? 0) > 300
            let power = fails ? Int(Double(target ?? 0) * 0.5) : (target ?? 120)
            ended = tracker.add(time: t, power: power, cadence: fails ? 40 : 90, target: target)
            t += 1
        }
        XCTAssertTrue(ended)
        let result = try? XCTUnwrap(tracker.result)
        XCTAssertEqual(result?.basis, 290)
        XCTAssertEqual(result?.ftp, 218) // 75 % of 290 W
        XCTAssertEqual(result?.plausible, true)
        XCTAssertEqual(tracker.effortPowers.count, 12 * 60 + 6)
    }

    func testRampTooShortIsNotPlausible() {
        let plan = FTPTestPlan.make(.ramp, ftp: 250, baseIsKnown: false)
        var tracker = FTPTestTracker(plan: plan)
        for t in 300..<420 { _ = tracker.add(time: Double(t), power: 150, cadence: 90, target: 140) }
        tracker.endManually()
        XCTAssertEqual(tracker.result?.plausible, false)
        XCTAssertNotNil(tracker.result?.reason)
    }

    func testTwentyMinutes() {
        let plan = FTPTestPlan.make(.twenty, ftp: 250, baseIsKnown: true)
        var tracker = FTPTestTracker(plan: plan)
        var ended = false
        for t in 0...2760 where !ended {
            ended = tracker.add(time: Double(t), power: 250, cadence: 90, target: nil)
        }
        XCTAssertTrue(ended)
        XCTAssertEqual(tracker.result?.basis, 250)
        XCTAssertEqual(tracker.result?.ftp, 238) // 95 % of 250 W
        XCTAssertEqual(tracker.result?.plausible, true)

        var aborted = FTPTestTracker(plan: plan)
        for t in 1560..<2160 { _ = aborted.add(time: Double(t), power: 260, cadence: 90, target: nil) }
        aborted.endManually()
        XCTAssertEqual(aborted.result?.plausible, false)
    }

    func testKnownFTPRejectsOutliers() {
        let plan = FTPTestPlan.make(.twenty, ftp: 250, baseIsKnown: true)
        var tracker = FTPTestTracker(plan: plan)
        for t in 1560...2760 { _ = tracker.add(time: Double(t), power: 120, cadence: 90, target: nil) }
        XCTAssertEqual(tracker.result?.plausible, false, "114 W is far below 60 % of 250 W")
    }

    // MARK: Taking over the result

    private func isolatedModel() -> AppModel {
        let model = AppModel.isolated(suite: "BikeAppFTPTests")
        model.settings.ftp = 250
        return model
    }

    func testPlausibleResultWithoutKeyWaitsForIt() {
        let model = isolatedModel()
        model.handleTestResult(FTPTestResult(kind: .ramp, ftp: 218, basis: 290, effortSeconds: 726, completed: true, plausible: true, reason: nil))
        XCTAssertEqual(model.settings.ftp, 218)
        XCTAssertEqual(model.settings.pendingFTPTransfer, 218)
        XCTAssertEqual(model.ftpOutcome?.transfer, .waitingForKey)

        model.undoFTP(model.ftpOutcome!)
        XCTAssertEqual(model.settings.ftp, 250)
        XCTAssertEqual(model.settings.pendingFTPTransfer, 0)
        XCTAssertEqual(model.ftpOutcome?.transfer, .undone)
    }

    func testImplausibleResultNeedsConfirmation() {
        let model = isolatedModel()
        model.handleTestResult(FTPTestResult(kind: .ramp, ftp: 140, basis: 187, effortSeconds: 120, completed: false, plausible: false, reason: "Die Rampe war kürzer als 4 Minuten."))
        XCTAssertEqual(model.settings.ftp, 250)
        if case .needsConfirmation = model.ftpOutcome?.transfer {} else { XCTFail("expected confirmation") }
    }

    // MARK: intervals.icu

    private func mockClient(athlete: String) -> IntervalsClient {
        MockURLProtocol.requests = []
        MockURLProtocol.handler = { request in
            switch request.httpMethod {
            case "GET": return (200, Data(athlete.utf8))
            case "PUT": return (200, Data("{}".utf8))
            default: return (404, Data())
            }
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let defaults = UserDefaults(suiteName: "BikeAppFTPMock")!
        defaults.removePersistentDomain(forName: "BikeAppFTPMock")
        return IntervalsClient(settings: AppSettings(defaults: defaults), session: URLSession(configuration: configuration), keychainAccount: "unused", apiKey: "test-key")
    }

    func testFTPIsWrittenToTheRideSettings() async throws {
        let client = mockClient(athlete: """
        { "name": "Test", "sportSettings": [
            { "id": 3015374, "types": ["Run"], "ftp": 276 },
            { "id": 3015373, "types": ["Ride", "VirtualRide"], "ftp": null, "indoor_ftp": null }
        ] }
        """)
        let change = try await client.updateFTP(218)
        XCTAssertEqual(change, FTPChange(settingsId: 3015373, field: "ftp", previous: nil, new: 218))

        let put = try XCTUnwrap(MockURLProtocol.requests.first { $0.method == "PUT" })
        XCTAssertEqual(put.url, "https://intervals.icu/api/v1/athlete/0/sport-settings/3015373")
        XCTAssertEqual(put.headers["Authorization"], "Basic " + Data("API_KEY:test-key".utf8).base64EncodedString())
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: put.body ?? Data()) as? [String: Any])
        XCTAssertEqual(body["ftp"] as? Int, 218)
        XCTAssertEqual(body.count, 1)

        MockURLProtocol.requests = []
        try await client.restoreFTP(change)
        let undo = try XCTUnwrap(MockURLProtocol.requests.first { $0.method == "PUT" })
        let undoBody = try XCTUnwrap(try JSONSerialization.jsonObject(with: undo.body ?? Data()) as? [String: Any])
        XCTAssertTrue(undoBody["ftp"] is NSNull, "undo clears the FTP again")
    }

    func testIndoorFTPIsUpdatedWhenSet() async throws {
        let client = mockClient(athlete: """
        { "sportSettings": [ { "id": 77, "types": ["Ride"], "ftp": 240, "indoor_ftp": 225 } ] }
        """)
        let change = try await client.updateFTP(231)
        XCTAssertEqual(change, FTPChange(settingsId: 77, field: "indoor_ftp", previous: 225, new: 231))
        let put = try XCTUnwrap(MockURLProtocol.requests.first { $0.method == "PUT" })
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: put.body ?? Data()) as? [String: Any])
        XCTAssertEqual(body["indoor_ftp"] as? Int, 231)
    }
}
