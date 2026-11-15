import CoreBluetooth
import Foundation
import Observation

enum ConnectionState: Equatable {
    case notAssigned
    case searching
    case connecting
    case connected
    case ready
    case failed(String)

    var isUsable: Bool { self == .ready || self == .connected }

    var label: String {
        switch self {
        case .notAssigned: return "Nicht gekoppelt"
        case .searching: return "Suche…"
        case .connecting: return "Verbinde…"
        case .connected: return "Verbunden"
        case .ready: return "Bereit"
        case let .failed(message): return message
        }
    }
}

struct DeviceStatus: Equatable {
    var name: String?
    var state: ConnectionState = .notAssigned
    var battery: Int?
    var detail: String?
}

struct DiscoveredDevice: Identifiable, Equatable {
    let id: UUID
    var name: String
    var rssi: Int
    var roles: [DeviceRole]
    var lastSeen: Date
}

/// Latest sensor values, with timestamps so stale values can be ignored.
struct LiveSensors: Equatable {
    var trainerPower: Int?
    var trainerCadence: Double?
    /// m/s, as reported by the trainer
    var trainerSpeed: Double?
    var trainerUpdated: Date?
    var heartRate: Int?
    var heartRateUpdated: Date?
    var pedalCadence: Double?
    var pedalUpdated: Date?

    private func fresh(_ date: Date?, _ now: Date, _ maxAge: TimeInterval = 3) -> Bool {
        guard let date else { return false }
        return now.timeIntervalSince(date) <= maxAge
    }

    func power(at now: Date) -> Int? { fresh(trainerUpdated, now) ? trainerPower : nil }

    /// Pedal sensor first, trainer cadence as fallback.
    func cadence(at now: Date) -> Double? {
        if fresh(pedalUpdated, now), let c = pedalCadence { return c }
        return fresh(trainerUpdated, now) ? trainerCadence : nil
    }

    func heartRate(at now: Date) -> Int? { fresh(heartRateUpdated, now, 5) ? heartRate : nil }

    func trainerSpeed(at now: Date) -> Double? { fresh(trainerUpdated, now) ? trainerSpeed : nil }

    var usesPedalCadence: Bool { fresh(pedalUpdated, Date()) }
}

@MainActor
protocol TrainerDevice: AnyObject {
    var isReady: Bool { get }
    func send(_ command: TrainerCommand)
}

/// Owns the Bluetooth central: scanning, pairing devices to roles, reconnecting.
@Observable @MainActor
final class BLEManager: NSObject {
    private(set) var bluetoothState: CBManagerState = .unknown
    private(set) var isScanning = false
    private(set) var discovered: [DiscoveredDevice] = []
    private(set) var status: [DeviceRole: DeviceStatus] = [:]
    var live = LiveSensors()

    @ObservationIgnored var onShift: ((ShiftDirection) -> Void)? {
        didSet { clickInput.onShift = onShift }
    }
    /// Both Click buttons pressed together.
    @ObservationIgnored var onBothButtons: (() -> Void)? {
        didSet { clickInput.onBothButtons = onBothButtons }
    }
    /// The trainer (re)gained control, e.g. after a reconnect: resend the current resistance.
    @ObservationIgnored var onTrainerReady: (() -> Void)?
    @ObservationIgnored private(set) var trainer: TrainerDevice?
    @ObservationIgnored let clickInput: ClickInputRouter
    /// Zwift device type from the advertisement, per peripheral.
    @ObservationIgnored private var zwiftTypes: [UUID: UInt8] = [:]

    /// Button learning in the devices sheet: which direction is asked for next.
    private(set) var learningDirection: ShiftDirection?
    /// Last button seen while learning (shown as feedback).
    private(set) var learnedSummary: String?

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private var central: CBCentralManager?
    @ObservationIgnored private var peripherals: [UUID: CBPeripheral] = [:]
    @ObservationIgnored private var handlers: [UUID: PeripheralHandler] = [:]
    @ObservationIgnored private var demo: DemoTrainer?
    @ObservationIgnored private var scanStopTask: Task<Void, Never>?

    init(settings: AppSettings) {
        self.settings = settings
        clickInput = ClickInputRouter(settings: settings)
        super.init()
        for role in DeviceRole.allCases {
            status[role] = DeviceStatus(state: assignedId(for: role) == nil ? .notAssigned : .searching)
        }
    }

    /// Roles shown in device lists: the Click v2 left half only once it is known.
    var visibleRoles: [DeviceRole] {
        DeviceRole.allCases.filter { role in
            !role.isOptionalExtra || status[role]?.state != .notAssigned || discovered.contains { $0.roles.contains(role) }
        }
    }

    func start() {
        if settings.demoMode { startDemo() }
        guard central == nil else { return }
        central = CBCentralManager(delegate: self, queue: .main)
    }

    // MARK: Demo

    var isDemo: Bool { demo != nil }

    func setDemoMode(_ enabled: Bool) {
        settings.demoMode = enabled
        if enabled { startDemo() } else { stopDemo() }
    }

    /// Demo for this launch only, without changing the saved setting.
    func startTemporaryDemo() {
        startDemo()
    }

    private func startDemo() {
        guard demo == nil else { return }
        let d = DemoTrainer(manager: self, settings: settings)
        demo = d
        trainer = d
        d.start()
        for role in [DeviceRole.trainer, .heartRate, .cadence] {
            status[role] = DeviceStatus(name: "Demo", state: .ready, detail: "Simuliert")
        }
    }

    private func stopDemo() {
        demo?.stop()
        demo = nil
        trainer = handlers.values.compactMap { $0 as? FTMSTrainerHandler }.first
        live = LiveSensors()
        for role in [DeviceRole.trainer, .heartRate, .cadence] {
            status[role] = DeviceStatus(state: assignedId(for: role) == nil ? .notAssigned : .searching)
        }
        reconnectAssigned()
    }

    // MARK: Commands

    func send(_ command: TrainerCommand) {
        trainer?.send(command)
    }

    // MARK: Scanning and pairing

    func startScan(duration: TimeInterval = 30) {
        guard let central, central.state == .poweredOn else { return }
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        isScanning = true
        scanStopTask?.cancel()
        scanStopTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            self?.stopScan()
        }
    }

    func stopScan() {
        central?.stopScan()
        isScanning = false
    }

    func assign(_ device: DiscoveredDevice, to role: DeviceRole) {
        // A device can only hold one role.
        for other in DeviceRole.allCases where assignedId(for: other) == device.id && other != role {
            unassign(other)
        }
        if let old = assignedId(for: role), old != device.id {
            disconnect(id: old)
        }
        settings.assignedDevices[role.rawValue] = device.id.uuidString
        status[role] = DeviceStatus(name: device.name, state: .connecting)
        if let p = peripherals[device.id] { connect(p) }
    }

    func unassign(_ role: DeviceRole) {
        if let id = assignedId(for: role) { disconnect(id: id) }
        settings.assignedDevices[role.rawValue] = nil
        status[role] = DeviceStatus(state: .notAssigned)
    }

    func assignedId(for role: DeviceRole) -> UUID? {
        settings.assignedDevices[role.rawValue].flatMap(UUID.init(uuidString:))
    }

    private func role(for id: UUID) -> DeviceRole? {
        DeviceRole.allCases.first { assignedId(for: $0) == id }
    }

    private func connect(_ peripheral: CBPeripheral) {
        peripherals[peripheral.identifier] = peripheral
        central?.connect(peripheral, options: nil)
    }

    private func disconnect(id: UUID) {
        handlers[id]?.cleanup()
        handlers[id] = nil
        if let p = peripherals[id] { central?.cancelPeripheralConnection(p) }
    }

    private func reconnectAssigned() {
        guard let central, central.state == .poweredOn else { return }
        var missing = false
        for role in DeviceRole.allCases {
            if settings.demoMode, !role.isClick { continue }
            guard let id = assignedId(for: role) else {
                missing = true
                continue
            }
            if let p = central.retrievePeripherals(withIdentifiers: [id]).first {
                status[role] = DeviceStatus(name: p.name, state: .connecting)
                connect(p)
            } else {
                status[role]?.state = .searching
                missing = true
            }
        }
        if missing { startScan() }
    }

    // MARK: Updates from handlers

    func updateTrainer(_ data: IndoorBikeData) {
        if let p = data.power { live.trainerPower = p }
        if let c = data.cadence { live.trainerCadence = c }
        if let s = data.speedKmh { live.trainerSpeed = s / 3.6 }
        live.trainerUpdated = Date()
    }

    func updateHeartRate(_ bpm: Int) {
        live.heartRate = bpm
        live.heartRateUpdated = Date()
    }

    func updatePedalCadence(_ rpm: Double) {
        live.pedalCadence = rpm
        live.pedalUpdated = Date()
    }

    func updateBattery(_ role: DeviceRole, _ level: Int) {
        status[role]?.battery = level
    }

    func updateState(_ role: DeviceRole, _ state: ConnectionState, detail: String? = nil) {
        status[role]?.state = state
        if let detail { status[role]?.detail = detail }
    }

    func handleShift(_ direction: ShiftDirection) {
        onShift?(direction)
    }

    func handleBothButtons() {
        onBothButtons?()
    }

    /// Pressed buttons of one controller; nil when it disconnected.
    func clickButtons(from source: UUID, pressed: Set<ClickButtonKey>?) {
        if let pressed {
            clickInput.update(source: source, pressed: pressed)
        } else {
            clickInput.remove(source: source)
        }
    }

    func trainerBecameReady(_ handler: FTMSTrainerHandler) {
        if demo == nil { trainer = handler }
        let model = DeviceClassifier.trainerModel(name: handler.peripheral.name ?? "")
        updateState(.trainer, .ready, detail: model.map { "Bereit · \($0)" } ?? "Bereit")
        onTrainerReady?()
    }

    func trainerCapabilitiesChanged() {
        onTrainerReady?()
    }

    /// False when the trainer says it cannot simulate slopes; gears then use ERG.
    var trainerSupportsSimulation: Bool {
        (trainer as? FTMSTrainerHandler)?.features.supportsSimulation ?? true
    }

    /// True when power or cadence data arrived recently, so pedalling can be detected.
    func hasMotionData(at now: Date) -> Bool {
        live.power(at: now) != nil || live.cadence(at: now) != nil
    }

    // MARK: Click button learning

    /// Starts learning: the rider presses the button for "schwerer", then for "leichter".
    func startLearningButtons() {
        learnedSummary = nil
        var learned: [String: String] = [:]
        learningDirection = .up
        clickInput.onLearn = { [weak self] key in
            guard let self, let direction = self.learningDirection else { return }
            if key.pod == .v1 {
                self.learnedSummary = "Der Click (v1) braucht keine Zuordnung."
                self.stopLearningButtons()
                return
            }
            learned[key.storageKey] = direction == .up ? "up" : "down"
            if direction == .up {
                self.learnedSummary = "Schwerer: \(key.label) der \(key.pod.title)"
                self.learningDirection = .down
            } else {
                self.settings.clickButtonMap = learned
                self.learnedSummary = "Gespeichert. Leichter: \(key.label) der \(key.pod.title)"
                self.stopLearningButtons()
            }
        }
    }

    func stopLearningButtons() {
        learningDirection = nil
        clickInput.onLearn = nil
    }

    func resetButtonMapping() {
        settings.clickButtonMap = [:]
        learnedSummary = "Standard: rechte Hälfte schaltet schwerer, linke leichter."
    }
}

extension BLEManager: @preconcurrency CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        bluetoothState = central.state
        switch central.state {
        case .poweredOn:
            reconnectAssigned()
        case .unauthorized:
            for role in DeviceRole.allCases where !(settings.demoMode && !role.isClick) {
                status[role]?.state = .failed("Kein Bluetooth-Zugriff")
            }
        case .poweredOff:
            for role in DeviceRole.allCases where !(settings.demoMode && !role.isClick) {
                status[role]?.state = .failed("Bluetooth aus")
            }
        default:
            break
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = peripheral.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? "Unbekannt"
        let services = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []
        let manufacturer = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data
        let roles = DeviceClassifier.roles(name: name, services: services, manufacturerData: manufacturer)
        guard !roles.isEmpty else { return }
        peripherals[peripheral.identifier] = peripheral
        if let type = DeviceClassifier.zwiftDeviceType(manufacturer) { zwiftTypes[peripheral.identifier] = type }

        let device = DiscoveredDevice(id: peripheral.identifier, name: name, rssi: RSSI.intValue, roles: roles, lastSeen: Date())
        if let i = discovered.firstIndex(where: { $0.id == device.id }) {
            discovered[i] = device
        } else {
            discovered.append(device)
        }

        // Known device found again: connect.
        if let role = role(for: peripheral.identifier) {
            if handlers[peripheral.identifier] == nil, peripheral.state == .disconnected {
                status[role] = DeviceStatus(name: name, state: .connecting)
                connect(peripheral)
            }
            return
        }
        // First device of a role that has none yet: pair automatically.
        for role in roles where assignedId(for: role) == nil {
            if settings.demoMode, !role.isClick { continue }
            assign(device, to: role)
            break
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard let role = role(for: peripheral.identifier) else {
            central.cancelPeripheralConnection(peripheral)
            return
        }
        let handler: PeripheralHandler
        switch role {
        case .trainer: handler = FTMSTrainerHandler(role: role, peripheral: peripheral, manager: self)
        case .click, .clickLeft:
            let pod = ZwiftDeviceType.pod(for: zwiftTypes[peripheral.identifier])
            handler = ZwiftClickHandler(role: role, peripheral: peripheral, manager: self, pod: pod)
        case .heartRate: handler = HeartRateHandler(role: role, peripheral: peripheral, manager: self)
        case .cadence: handler = CadenceHandler(role: role, peripheral: peripheral, manager: self)
        }
        handlers[peripheral.identifier] = handler
        status[role] = DeviceStatus(name: peripheral.name ?? status[role]?.name, state: .connected, battery: status[role]?.battery)
        handler.start()
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard let role = role(for: peripheral.identifier) else { return }
        status[role]?.state = .connecting
        connect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        let handler = handlers.removeValue(forKey: peripheral.identifier)
        handler?.cleanup()
        if let t = handler as? FTMSTrainerHandler, trainer === t { trainer = demo }
        guard let role = role(for: peripheral.identifier) else { return }
        status[role]?.state = .connecting
        // Pending connect requests do not time out, so the device reconnects when it comes back.
        connect(peripheral)
    }
}
