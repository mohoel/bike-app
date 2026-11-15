import CoreBluetooth
import XCTest
@testable import BikeApp

final class SensorParserTests: XCTestCase {
    func testIndoorBikeDataWithSpeedCadencePower() {
        // flags 0x0044: speed present (bit 0 clear), cadence (bit 2), power (bit 6)
        let bytes: [UInt8] = [0x44, 0x00, 0xA8, 0x0C, 0xB0, 0x00, 0xF5, 0x00]
        let data = IndoorBikeData.parse(bytes)
        XCTAssertEqual(data?.speedKmh ?? 0, 32.4, accuracy: 0.001)
        XCTAssertEqual(data?.cadence ?? 0, 88, accuracy: 0.001)
        XCTAssertEqual(data?.power, 245)
    }

    func testIndoorBikeDataMoreDataPacketHasNoSpeed() {
        // flags 0x0041: "more data" (no speed) plus power
        let bytes: [UInt8] = [0x41, 0x00, 0x2C, 0x01]
        let data = IndoorBikeData.parse(bytes)
        XCTAssertNil(data?.speedKmh)
        XCTAssertEqual(data?.power, 300)
    }

    func testIndoorBikeDataSkipsOptionalFields() {
        // speed, avg speed (bit1), cadence, total distance (bit4), power, heart rate (bit9)
        let flags: UInt16 = 0x0002 | 0x0004 | 0x0010 | 0x0040 | 0x0200
        let bytes: [UInt8] = [UInt8(flags & 0xFF), UInt8(flags >> 8),
                              0x10, 0x27, // speed 100.00
                              0x00, 0x00, // avg speed
                              0xB4, 0x00, // cadence 90
                              0x10, 0x27, 0x00, // distance 10000 m
                              0xC8, 0x00, // power 200
                              0x8C] // hr 140
        let data = IndoorBikeData.parse(bytes)
        XCTAssertEqual(data?.speedKmh ?? 0, 100, accuracy: 0.001)
        XCTAssertEqual(data?.cadence ?? 0, 90, accuracy: 0.001)
        XCTAssertEqual(data?.totalDistance, 10_000)
        XCTAssertEqual(data?.power, 200)
        XCTAssertEqual(data?.heartRate, 140)
    }

    func testFTMSCommandEncoding() {
        XCTAssertEqual(FTMSCommand.encode(.targetPower(watts: 230)), [0x05, 0xE6, 0x00])
        XCTAssertEqual(FTMSCommand.encode(.simulation(gradePercent: 4.5, crr: 0.004, windResistance: 0.51)), [0x11, 0x00, 0x00, 0xC2, 0x01, 40, 51])
        XCTAssertEqual(FTMSCommand.encode(.simulation(gradePercent: -2.5, crr: 0.004, windResistance: 0.38)), [0x11, 0x00, 0x00, 0x06, 0xFF, 40, 38])
        XCTAssertEqual(FTMSCommand.parseResponse([0x80, 0x00, 0x01])?.result, 0x01)
        XCTAssertNil(FTMSCommand.parseResponse([0x11, 0x00]))
    }

    func testHeartRate() {
        XCTAssertEqual(HeartRateParser.parse([0x00, 72]), 72)
        XCTAssertEqual(HeartRateParser.parse([0x01, 0x2C, 0x01]), 300)
        XCTAssertNil(HeartRateParser.parse([0x00]))
    }

    func testCrankCadenceWithRollover() {
        var calc = CrankCadenceCalculator()
        calc.update([0x02, 0xFE, 0xFF, 0x00, 0xFA], now: 0)
        // 3 revolutions (65534 -> 1) in 2048/1024 s = 2 s -> 90 rpm; event time wraps too
        let rpm = calc.update([0x02, 0x01, 0x00, 0x00, 0x02], now: 2)
        XCTAssertEqual(rpm ?? 0, 90, accuracy: 0.01)
        // Same values again (no new crank event) keep the cadence for a moment, then drop to 0.
        XCTAssertEqual(calc.update([0x02, 0x01, 0x00, 0x00, 0x02], now: 3) ?? -1, 90, accuracy: 0.01)
        XCTAssertEqual(calc.update([0x02, 0x01, 0x00, 0x00, 0x02], now: 5) ?? -1, 0, accuracy: 0.01)
    }

    func testCrankCadenceSkipsWheelData() {
        var calc = CrankCadenceCalculator()
        let wheel: [UInt8] = [0, 0, 0, 0, 0, 0]
        calc.update([0x03] + wheel + [0x0A, 0x00, 0x00, 0x04], now: 0)
        let rpm = calc.update([0x03] + wheel + [0x0B, 0x00, 0xAB, 0x06], now: 1)
        // 1 revolution in (0x06AB - 0x0400) / 1024 s = 0.667 s -> 90 rpm
        XCTAssertEqual(rpm ?? 0, 90, accuracy: 0.1)
    }

    func testZwiftClickMessages() {
        XCTAssertEqual(ZwiftClickProtocol.decode(ZwiftClickProtocol.rideOn + [0x01, 0x03]), .handshake(encrypted: false))
        XCTAssertEqual(ZwiftClickProtocol.decode(ZwiftClickProtocol.rideOn + [0x01, 0x03] + Array(repeating: 0xAA, count: 64)), .handshake(encrypted: true))
        XCTAssertEqual(ZwiftClickProtocol.decode([0x37, 0x08, 0x00, 0x10, 0x01]), .buttons(.init(plus: true, minus: false)))
        XCTAssertEqual(ZwiftClickProtocol.decode([0x37, 0x08, 0x01, 0x10, 0x00]), .buttons(.init(plus: false, minus: true)))
        XCTAssertEqual(ZwiftClickProtocol.decode([0x37, 0x08, 0x01, 0x10, 0x01]), .buttons(.init(plus: false, minus: false)))
        XCTAssertEqual(ZwiftClickProtocol.decode([0x19, 0x08, 0x55]), .battery(85))
        XCTAssertEqual(ZwiftClickProtocol.decode([0x15]), .keepAlive)
    }

    func testDeviceClassification() {
        XCTAssertEqual(DeviceClassifier.roles(name: "KICKR CORE 5A1B", services: [], manufacturerData: nil), [.trainer])
        XCTAssertEqual(DeviceClassifier.roles(name: "Trainer", services: [BLEUUID.ftmsService, BLEUUID.cscService], manufacturerData: nil), [.trainer])
        XCTAssertEqual(DeviceClassifier.roles(name: "Zwift Click", services: [], manufacturerData: Data([0x4A, 0x09, 0x09])), [.click])
        XCTAssertEqual(DeviceClassifier.roles(name: "TICKR", services: [BLEUUID.heartRateService], manufacturerData: nil), [.heartRate])
        XCTAssertEqual(DeviceClassifier.roles(name: "RPM", services: [BLEUUID.cscService], manufacturerData: nil), [.cadence])
        XCTAssertEqual(DeviceClassifier.roles(name: "Kopfhörer", services: [], manufacturerData: nil), [])
    }
}
