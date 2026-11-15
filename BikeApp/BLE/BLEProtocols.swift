import CoreBluetooth
import Foundation

enum BLEUUID {
    static let ftmsService = CBUUID(string: "1826")
    static let indoorBikeData = CBUUID(string: "2AD2")
    static let ftmsControlPoint = CBUUID(string: "2AD9")
    static let ftmsStatus = CBUUID(string: "2ADA")
    static let cyclingPowerService = CBUUID(string: "1818")
    static let heartRateService = CBUUID(string: "180D")
    static let heartRateMeasurement = CBUUID(string: "2A37")
    static let cscService = CBUUID(string: "1816")
    static let cscMeasurement = CBUUID(string: "2A5B")
    static let batteryService = CBUUID(string: "180F")
    static let batteryLevel = CBUUID(string: "2A19")
    static let zwiftService = CBUUID(string: "00000001-19CA-4651-86E5-FA29DCDD09D1")
    static let zwiftAsync = CBUUID(string: "00000002-19CA-4651-86E5-FA29DCDD09D1")
    static let zwiftSyncRx = CBUUID(string: "00000003-19CA-4651-86E5-FA29DCDD09D1")
    static let zwiftSyncTx = CBUUID(string: "00000004-19CA-4651-86E5-FA29DCDD09D1")
    /// Zwift's 16-bit service. Ride and Click v2 expose the Zwift characteristics under it.
    static let zwiftAdvertised = CBUUID(string: "FC82")
    static let fitnessMachineFeature = CBUUID(string: "2ACC")
    static let supportedPowerRange = CBUUID(string: "2AD8")
    static let zwiftManufacturerId: UInt16 = 0x094A
}

/// Little-endian reader for BLE characteristic values.
struct ByteReader {
    private let bytes: [UInt8]
    private(set) var offset = 0

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    var remaining: Int { bytes.count - offset }

    mutating func u8() -> UInt8? {
        guard remaining >= 1 else { return nil }
        defer { offset += 1 }
        return bytes[offset]
    }

    mutating func u16() -> UInt16? {
        guard remaining >= 2 else { return nil }
        defer { offset += 2 }
        return UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }

    mutating func s16() -> Int16? {
        u16().map { Int16(bitPattern: $0) }
    }

    mutating func u24() -> UInt32? {
        guard remaining >= 3 else { return nil }
        defer { offset += 3 }
        return UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2]) << 16
    }

    mutating func u32() -> UInt32? {
        guard remaining >= 4 else { return nil }
        defer { offset += 4 }
        return UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
    }

    mutating func skip(_ n: Int) {
        offset = Swift.min(bytes.count, offset + n)
    }
}

// MARK: - FTMS

/// One FTMS Indoor Bike Data notification. Only fields present in the packet are set.
struct IndoorBikeData: Equatable {
    var speedKmh: Double?
    var cadence: Double?
    var totalDistance: Double?
    var resistance: Int?
    var power: Int?
    var heartRate: Int?

    static func parse(_ bytes: [UInt8]) -> IndoorBikeData? {
        var r = ByteReader(bytes)
        guard let flags = r.u16() else { return nil }
        var d = IndoorBikeData()
        if flags & 0x0001 == 0 { d.speedKmh = r.u16().map { Double($0) / 100 } }
        if flags & 0x0002 != 0 { r.skip(2) }
        if flags & 0x0004 != 0 { d.cadence = r.u16().map { Double($0) / 2 } }
        if flags & 0x0008 != 0 { r.skip(2) }
        if flags & 0x0010 != 0 { d.totalDistance = r.u24().map(Double.init) }
        if flags & 0x0020 != 0 { d.resistance = r.s16().map(Int.init) }
        if flags & 0x0040 != 0 { d.power = r.s16().map(Int.init) }
        if flags & 0x0080 != 0 { r.skip(2) }
        if flags & 0x0100 != 0 { r.skip(5) }
        if flags & 0x0200 != 0 { d.heartRate = r.u8().map(Int.init) }
        return d
    }
}

enum FTMSCommand {
    static let requestControl: [UInt8] = [0x00]
    static let reset: [UInt8] = [0x01]
    static let start: [UInt8] = [0x07]

    static func encode(_ command: TrainerCommand) -> [UInt8] {
        switch command {
        case let .targetPower(watts):
            return [0x05] + le16(Int16(clamping: watts))
        case let .simulation(grade, crr, wind):
            let gradeRaw = Int16(clamping: Int((grade * 100).rounded()))
            let crrRaw = UInt8(clamping: Int((crr * 10_000).rounded()))
            let windRaw = UInt8(clamping: Int((wind * 100).rounded()))
            return [0x11] + le16(0) + le16(gradeRaw) + [crrRaw, windRaw]
        }
    }

    private static func le16(_ v: Int16) -> [UInt8] {
        let u = UInt16(bitPattern: v)
        return [UInt8(u & 0xFF), UInt8(u >> 8)]
    }

    /// Parses a control point indication: (request opcode, result code).
    static func parseResponse(_ bytes: [UInt8]) -> (opcode: UInt8, result: UInt8)? {
        guard bytes.count >= 3, bytes[0] == 0x80 else { return nil }
        return (bytes[1], bytes[2])
    }
}

/// What the trainer says it can do (Fitness Machine Feature characteristic).
struct FTMSFeatures: Equatable {
    var supportsPowerTarget: Bool
    var supportsSimulation: Bool

    static let assumed = FTMSFeatures(supportsPowerTarget: true, supportsSimulation: true)

    static func parse(_ bytes: [UInt8]) -> FTMSFeatures? {
        var r = ByteReader(bytes)
        guard r.u32() != nil, let targets = r.u32() else { return nil }
        return FTMSFeatures(supportsPowerTarget: targets & 0x0008 != 0, supportsSimulation: targets & 0x2000 != 0)
    }
}

/// Supported Power Range: ERG targets outside it are clamped.
struct PowerRange: Equatable {
    var minimum: Int
    var maximum: Int

    static func parse(_ bytes: [UInt8]) -> PowerRange? {
        var r = ByteReader(bytes)
        guard let lo = r.s16(), let hi = r.s16(), hi > lo, hi > 0 else { return nil }
        return PowerRange(minimum: Swift.max(0, Int(lo)), maximum: Int(hi))
    }

    func clamp(_ watts: Int) -> Int { Swift.min(maximum, Swift.max(minimum, watts)) }
}

// MARK: - Heart rate and cadence

enum HeartRateParser {
    static func parse(_ bytes: [UInt8]) -> Int? {
        guard bytes.count >= 2 else { return nil }
        if bytes[0] & 0x01 == 0 { return Int(bytes[1]) }
        guard bytes.count >= 3 else { return nil }
        return Int(UInt16(bytes[1]) | UInt16(bytes[2]) << 8)
    }
}

/// Cadence from a CSC (cycling speed and cadence) sensor, e.g. a pedal or crank sensor.
struct CrankCadenceCalculator {
    private var lastRevolutions: UInt16?
    private var lastEventTime: UInt16?
    private var lastChange: TimeInterval = 0
    private(set) var cadence: Double = 0

    /// Feeds one CSC measurement. `now` is a monotonic time in seconds.
    @discardableResult
    mutating func update(_ bytes: [UInt8], now: TimeInterval) -> Double? {
        var r = ByteReader(bytes)
        guard let flags = r.u8() else { return nil }
        if flags & 0x01 != 0 { r.skip(6) }
        guard flags & 0x02 != 0, let revs = r.u16(), let time = r.u16() else { return nil }
        if let lastRevs = lastRevolutions, let lastTime = lastEventTime {
            let dRev = revs &- lastRevs
            let dTime = time &- lastTime
            if dRev > 0, dTime > 0 {
                let rpm = Double(dRev) * 60 * 1024 / Double(dTime)
                if rpm < 250 { cadence = rpm }
                lastChange = now
            } else if now - lastChange > 2.5 {
                cadence = 0
            }
        } else {
            lastChange = now
        }
        lastRevolutions = revs
        lastEventTime = time
        return cadence
    }
}

// MARK: - Zwift Click

/// Which Zwift controller a button belongs to.
enum ClickPod: String, Codable, Equatable {
    /// Original Zwift Click: one device with + and −.
    case v1
    /// Click v2 right half (the "+" pod).
    case right
    /// Click v2 left half (the "−" pod).
    case left

    var title: String {
        switch self {
        case .v1: return "Click"
        case .right: return "rechte Hälfte (+)"
        case .left: return "linke Hälfte (−)"
        }
    }
}

/// One physical button: the pod plus a protocol-specific id (v1: 1 = plus, 2 = minus; v2: bit of the button map).
struct ClickButtonKey: Hashable, Codable {
    var pod: ClickPod
    var id: UInt32

    static let v1Plus = ClickButtonKey(pod: .v1, id: 1)
    static let v1Minus = ClickButtonKey(pod: .v1, id: 2)

    var storageKey: String { "\(pod.rawValue):\(id)" }

    /// "+", "−" or "Taste 13" (bit number of the Click v2 button map).
    var label: String {
        switch self {
        case .v1Plus: return "+"
        case .v1Minus: return "−"
        default: return "Taste \(id.trailingZeroBitCount + 1)"
        }
    }

    init(pod: ClickPod, id: UInt32) {
        self.pod = pod
        self.id = id
    }

    init?(storageKey: String) {
        let parts = storageKey.split(separator: ":")
        guard parts.count == 2, let pod = ClickPod(rawValue: String(parts[0])), let id = UInt32(parts[1]) else { return nil }
        self.init(pod: pod, id: id)
    }
}

enum ZwiftClickProtocol {
    static let rideOn: [UInt8] = Array("RideOn".utf8)
    /// Click v1 button notification.
    static let clickNotification: UInt8 = 0x37
    /// Zwift Ride / Click v2 button map notification.
    static let rideKeyPadNotification: UInt8 = 0x23
    static let batteryNotification: UInt8 = 0x19
    static let emptyMessage: UInt8 = 0x15
    /// Written to the Click v2 after the handshake; keeps an unlocked left pod unlocked across reconnects.
    static let unlockAck: [UInt8] = [0xFF, 0x04, 0x00]

    struct Buttons: Equatable {
        var plus = false
        var minus = false
    }

    enum Message: Equatable {
        case handshake(encrypted: Bool)
        /// Click v2 left pod that Zwift has not unlocked in the last ~24 h answers with a challenge.
        case locked
        case buttons(Buttons)
        /// Raw Ride/Click v2 button map (bit cleared = pressed).
        case buttonMap(UInt32)
        case battery(Int)
        case keepAlive
        case other(UInt8)
    }

    static func decode(_ bytes: [UInt8]) -> Message? {
        guard let first = bytes.first else { return nil }
        if bytes.count >= rideOn.count, Array(bytes.prefix(rideOn.count)) == rideOn {
            // A plain response is "RideOn" plus two bytes; a long tail is a public key (encrypted mode).
            return .handshake(encrypted: bytes.count > rideOn.count + 8)
        }
        let body = Array(bytes.dropFirst())
        switch first {
        case clickNotification:
            let fields = varintFields(body)
            // Button status enum: 0 = pressed, 1 = released.
            let plus = fields[1].map { $0 == 0 } ?? false
            let minus = fields[2].map { $0 == 0 } ?? false
            return .buttons(Buttons(plus: plus, minus: minus))
        case rideKeyPadNotification:
            guard let map = varintFields(body)[1] else { return .other(first) }
            return .buttonMap(UInt32(truncatingIfNeeded: map))
        case batteryNotification:
            let fields = varintFields(body)
            if let level = fields[1] ?? fields[2] { return .battery(Int(level)) }
            return .other(first)
        case emptyMessage:
            return .keepAlive
        case 0xFF:
            return .locked
        default:
            return .other(first)
        }
    }

    /// Minimal protobuf reader: returns all varint fields by field number.
    static func varintFields(_ bytes: [UInt8]) -> [Int: UInt64] {
        var result: [Int: UInt64] = [:]
        var i = 0
        func readVarint() -> UInt64? {
            var value: UInt64 = 0
            var shift: UInt64 = 0
            while i < bytes.count {
                let b = bytes[i]
                i += 1
                value |= UInt64(b & 0x7F) << shift
                if b & 0x80 == 0 { return value }
                shift += 7
                if shift > 63 { return nil }
            }
            return nil
        }
        while i < bytes.count {
            guard let key = readVarint() else { break }
            let field = Int(key >> 3)
            switch key & 0x7 {
            case 0:
                guard let v = readVarint() else { return result }
                result[field] = v
            case 1:
                i += 8
            case 2:
                guard let len = readVarint() else { return result }
                i += Int(len)
            case 5:
                i += 4
            default:
                return result
            }
        }
        return result
    }
}

/// Turns the Click v2 inverted button map into the set of pressed bits.
///
/// Only bits that have been seen released at least once count, so unused bits that
/// are always 0 never look like a held button.
struct ButtonMapTracker {
    private(set) var knownButtons: UInt32 = 0

    mutating func pressed(_ map: UInt32) -> [UInt32] {
        knownButtons |= map
        let down = knownButtons & ~map
        return (0..<32).compactMap { bit in
            let mask = UInt32(1) << UInt32(bit)
            return down & mask != 0 ? mask : nil
        }
    }
}

/// Turns Click button states into actions: one press shifts, both buttons together pause.
struct ClickButtonInterpreter {
    enum Action: Equatable {
        case shift(ShiftDirection)
        case startRepeat(ShiftDirection)
        case stopRepeat
        case bothPressed
    }

    private(set) var buttons = ZwiftClickProtocol.Buttons()
    private var comboActive = false

    func isHeld(_ direction: ShiftDirection) -> Bool {
        !comboActive && (direction == .up ? buttons.plus : buttons.minus)
    }

    mutating func process(_ new: ZwiftClickProtocol.Buttons) -> [Action] {
        defer { buttons = new }
        let bothNow = new.plus && new.minus
        if bothNow, !(buttons.plus && buttons.minus) {
            comboActive = true
            var actions: [Action] = [.stopRepeat]
            // The button pressed first already shifted: take that shift back.
            if buttons.plus { actions.append(.shift(.down)) }
            if buttons.minus { actions.append(.shift(.up)) }
            actions.append(.bothPressed)
            return actions
        }
        if comboActive {
            // Ignore everything until both buttons are released.
            if !new.plus, !new.minus { comboActive = false }
            return []
        }
        var actions: [Action] = []
        if new.plus, !buttons.plus { actions += [.shift(.up), .startRepeat(.up)] }
        if new.minus, !buttons.minus { actions += [.shift(.down), .startRepeat(.down)] }
        if !new.plus, !new.minus, buttons.plus || buttons.minus { actions.append(.stopRepeat) }
        return actions
    }
}

// MARK: - Device classification

enum DeviceRole: String, CaseIterable, Identifiable, Codable {
    case trainer
    case click
    /// Left half of the Click v2 (the original Click has only one device).
    case clickLeft
    case heartRate
    case cadence

    var id: String { rawValue }

    var title: String {
        switch self {
        case .trainer: return "Trainer"
        case .click: return "Zwift Click"
        case .clickLeft: return "Click v2 links (−)"
        case .heartRate: return "Pulsgurt"
        case .cadence: return "Kadenz"
        }
    }

    var shortLabel: String {
        switch self {
        case .trainer: return "KICKR"
        case .click: return "CLICK"
        case .clickLeft: return "CLICK −"
        case .heartRate: return "PULS"
        case .cadence: return "KADENZ"
        }
    }

    var isClick: Bool { self == .click || self == .clickLeft }

    /// Optional roles never block a ride and stay hidden until a device shows up.
    var isOptionalExtra: Bool { self == .clickLeft }

    var symbol: String {
        switch self {
        case .trainer: return "bicycle"
        case .click: return "plusminus.circle"
        case .clickLeft: return "minus.circle"
        case .heartRate: return "heart"
        case .cadence: return "metronome"
        }
    }
}

/// Device type byte in Zwift's manufacturer data (company 0x094A, then type, then short address).
enum ZwiftDeviceType {
    static let click: UInt8 = 0x09
    static let clickV2Right: UInt8 = 0x0A
    static let clickV2Left: UInt8 = 0x0B

    static func pod(for type: UInt8?) -> ClickPod? {
        switch type {
        case clickV2Right: return .right
        case clickV2Left: return .left
        case click: return .v1
        default: return nil
        }
    }
}

enum DeviceClassifier {
    /// Zwift device type from the advertisement, or nil for other manufacturers.
    static func zwiftDeviceType(_ manufacturerData: Data?) -> UInt8? {
        guard let data = manufacturerData, data.count >= 2 else { return nil }
        let bytes = [UInt8](data)
        let company = UInt16(bytes[0]) | UInt16(bytes[1]) << 8
        guard company == BLEUUID.zwiftManufacturerId else { return nil }
        return bytes.count >= 3 ? bytes[2] : 0
    }

    /// Readable trainer model for the device list, e.g. "KICKR CORE 2".
    static func trainerModel(name: String) -> String? {
        let upper = name.uppercased()
        if upper.contains("KICKR CORE 2") || upper.contains("KICKRCORE2") { return "Kickr Core 2" }
        if upper.contains("KICKR CORE") { return "Kickr Core" }
        if upper.contains("KICKR") { return "Kickr" }
        return nil
    }

    static func roles(name: String, services: [CBUUID], manufacturerData: Data?) -> [DeviceRole] {
        let upper = name.uppercased()
        if services.contains(BLEUUID.ftmsService) || upper.contains("KICKR") {
            return [.trainer]
        }
        if let type = zwiftDeviceType(manufacturerData) {
            return type == ZwiftDeviceType.clickV2Left ? [.clickLeft] : [.click]
        }
        if upper.contains("ZWIFT CLICK") || upper.contains("ZWIFT SF2") || services.contains(BLEUUID.zwiftAdvertised) {
            return [.click]
        }
        var roles: [DeviceRole] = []
        if services.contains(BLEUUID.heartRateService) { roles.append(.heartRate) }
        if services.contains(BLEUUID.cscService) { roles.append(.cadence) }
        return roles
    }
}
