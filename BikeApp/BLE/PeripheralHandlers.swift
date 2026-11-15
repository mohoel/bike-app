import CoreBluetooth
import Foundation

/// Base class: discovers services and routes characteristic updates.
@MainActor
class PeripheralHandler: NSObject, @preconcurrency CBPeripheralDelegate {
    let role: DeviceRole
    let peripheral: CBPeripheral
    weak var manager: BLEManager?

    init(role: DeviceRole, peripheral: CBPeripheral, manager: BLEManager) {
        self.role = role
        self.peripheral = peripheral
        self.manager = manager
        super.init()
        peripheral.delegate = self
    }

    var serviceUUIDs: [CBUUID]? { nil }

    func start() {
        peripheral.discoverServices(serviceUUIDs)
    }

    func cleanup() {}

    /// Called for every discovered characteristic.
    func configure(_ characteristic: CBCharacteristic) {
        if characteristic.uuid == BLEUUID.batteryLevel {
            peripheral.readValue(for: characteristic)
            if characteristic.properties.contains(.notify) {
                peripheral.setNotifyValue(true, for: characteristic)
            }
        }
    }

    /// Called after all characteristics of all services were discovered.
    func didFinishDiscovery() {}

    func handle(_ value: [UInt8], from characteristic: CBCharacteristic) {
        if characteristic.uuid == BLEUUID.batteryLevel, let level = value.first {
            manager?.updateBattery(role, Int(level))
        }
    }

    func notificationsEnabled(for characteristic: CBCharacteristic) {}

    private var pendingServices = 0

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        let services = peripheral.services ?? []
        pendingServices = services.count
        if services.isEmpty { didFinishDiscovery() }
        for service in services {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for c in service.characteristics ?? [] { configure(c) }
        pendingServices -= 1
        if pendingServices <= 0 { didFinishDiscovery() }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, let data = characteristic.value else { return }
        handle([UInt8](data), from: characteristic)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, characteristic.isNotifying else { return }
        notificationsEnabled(for: characteristic)
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {}
}

// MARK: - Trainer (FTMS)

@MainActor
final class FTMSTrainerHandler: PeripheralHandler, TrainerDevice {
    private var controlPoint: CBCharacteristic?
    private(set) var isReady = false
    private var hasControl = false
    private var controlQueue: [[UInt8]] = []
    private var pendingSetting: TrainerCommand?
    private var awaitingSince: Date?
    private var retryTask: Task<Void, Never>?
    /// Last resistance command, sent again after the trainer gave control back (reset, sleep, reconnect).
    private var lastSetting: TrainerCommand?
    private(set) var features = FTMSFeatures.assumed
    private(set) var powerRange: PowerRange?

    override var serviceUUIDs: [CBUUID]? { [BLEUUID.ftmsService, BLEUUID.batteryService] }

    override func configure(_ c: CBCharacteristic) {
        switch c.uuid {
        case BLEUUID.indoorBikeData, BLEUUID.ftmsStatus:
            peripheral.setNotifyValue(true, for: c)
        case BLEUUID.fitnessMachineFeature, BLEUUID.supportedPowerRange:
            peripheral.readValue(for: c)
        case BLEUUID.ftmsControlPoint:
            controlPoint = c
            peripheral.setNotifyValue(true, for: c)
        default:
            super.configure(c)
        }
    }

    override func didFinishDiscovery() {
        if controlPoint == nil {
            manager?.updateState(.trainer, .failed("Kein FTMS"), detail: "Trainer-Firmware aktualisieren (Wahoo-App)")
        } else if let model = DeviceClassifier.trainerModel(name: peripheral.name ?? "") {
            manager?.updateState(.trainer, .connected, detail: "\(model) · übernehme Steuerung…")
        }
    }

    override func notificationsEnabled(for c: CBCharacteristic) {
        guard c.uuid == BLEUUID.ftmsControlPoint else { return }
        takeControl()
    }

    override func cleanup() {
        retryTask?.cancel()
        isReady = false
    }

    private func takeControl() {
        hasControl = false
        isReady = false
        controlQueue = [FTMSCommand.requestControl, FTMSCommand.start]
        awaitingSince = nil
        pump()
    }

    override func handle(_ value: [UInt8], from c: CBCharacteristic) {
        switch c.uuid {
        case BLEUUID.indoorBikeData:
            if let data = IndoorBikeData.parse(value) { manager?.updateTrainer(data) }
        case BLEUUID.ftmsControlPoint:
            handleResponse(value)
        case BLEUUID.fitnessMachineFeature:
            if let parsed = FTMSFeatures.parse(value) {
                features = parsed
                manager?.trainerCapabilitiesChanged()
            }
        case BLEUUID.supportedPowerRange:
            powerRange = PowerRange.parse(value)
        case BLEUUID.ftmsStatus:
            guard let op = value.first else { return }
            switch op {
            case 0x01, 0xFF:
                // Reset or control permission lost: ask for control again.
                takeControl()
            case 0x02, 0x04:
                // Stopped by the user or by safety key: start again so the next command is accepted.
                if isReady { controlQueue.append(FTMSCommand.start); pump() }
            default:
                break
            }
        default:
            super.handle(value, from: c)
        }
    }

    private func handleResponse(_ value: [UInt8]) {
        guard let (op, result) = FTMSCommand.parseResponse(value) else { return }
        awaitingSince = nil
        if result == 0x05 { // control not permitted
            takeControl()
            return
        }
        if op == 0x00 { hasControl = result == 0x01 }
        if op == 0x07, hasControl, !isReady {
            isReady = true
            if pendingSetting == nil { pendingSetting = lastSetting }
            manager?.trainerBecameReady(self)
        }
        pump()
    }

    func send(_ command: TrainerCommand) {
        var command = command
        if case let .targetPower(watts) = command, let range = powerRange {
            command = .targetPower(watts: range.clamp(watts))
        }
        pendingSetting = command
        lastSetting = command
        pump()
    }

    private func pump() {
        guard let cp = controlPoint else { return }
        if let since = awaitingSince, Date().timeIntervalSince(since) < 2 { return }
        let bytes: [UInt8]
        if !controlQueue.isEmpty {
            bytes = controlQueue.removeFirst()
        } else if isReady, let command = pendingSetting {
            bytes = FTMSCommand.encode(command)
            pendingSetting = nil
        } else {
            return
        }
        awaitingSince = Date()
        peripheral.writeValue(Data(bytes), for: cp, type: .withResponse)
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.1))
            guard !Task.isCancelled else { return }
            self?.pump()
        }
    }
}

// MARK: - Zwift Click

/// Original Zwift Click and both halves of the Click v2.
///
/// The Click v2 is two devices that speak the Zwift Ride protocol: the Zwift characteristics sit
/// under service FC82, buttons arrive as an inverted bit map (message 0x23), and each half goes
/// to sleep after about a minute without traffic, so the app repeats "RideOn" every few seconds.
@MainActor
final class ZwiftClickHandler: PeripheralHandler {
    private var syncRx: CBCharacteristic?
    private var hasSyncTx = false
    private var asyncReady = false
    private var syncTxReady = false
    private var handshakeSent = false
    private var handshakeDone = false
    private var mapTracker = ButtonMapTracker()
    private var handshakeTimeout: Task<Void, Never>?
    private var keepAliveTask: Task<Void, Never>?
    /// Set from the advertisement or detected from the services / messages.
    private(set) var pod: ClickPod

    init(role: DeviceRole, peripheral: CBPeripheral, manager: BLEManager, pod: ClickPod?) {
        self.pod = pod ?? (role == .clickLeft ? .left : .v1)
        super.init(role: role, peripheral: peripheral, manager: manager)
    }

    private var isV2: Bool { pod != .v1 }

    override var serviceUUIDs: [CBUUID]? { [BLEUUID.zwiftService, BLEUUID.zwiftAdvertised, BLEUUID.batteryService] }

    override func configure(_ c: CBCharacteristic) {
        if c.service?.uuid == BLEUUID.zwiftAdvertised, pod == .v1 {
            // Characteristics under FC82: this is a Click v2 half.
            pod = role == .clickLeft ? .left : .right
        }
        switch c.uuid {
        case BLEUUID.zwiftAsync:
            peripheral.setNotifyValue(true, for: c)
        case BLEUUID.zwiftSyncTx:
            hasSyncTx = true
            peripheral.setNotifyValue(true, for: c)
        case BLEUUID.zwiftSyncRx:
            syncRx = c
        default:
            super.configure(c)
        }
    }

    override func didFinishDiscovery() {
        if syncRx == nil {
            manager?.updateState(role, .failed("Unbekanntes Gerät"))
        }
        sendHandshakeIfReady()
    }

    override func notificationsEnabled(for c: CBCharacteristic) {
        if c.uuid == BLEUUID.zwiftAsync { asyncReady = true }
        if c.uuid == BLEUUID.zwiftSyncTx { syncTxReady = true }
        sendHandshakeIfReady()
    }

    override func cleanup() {
        handshakeTimeout?.cancel()
        keepAliveTask?.cancel()
        manager?.clickButtons(from: peripheral.identifier, pressed: nil)
    }

    private var readyDetail: String {
        switch pod {
        case .v1: return "Bereit"
        case .right: return "Bereit · Click v2 rechts (+)"
        case .left: return "Bereit · Click v2 links (−)"
        }
    }

    private func write(_ bytes: [UInt8]) {
        guard let rx = syncRx else { return }
        let type: CBCharacteristicWriteType = rx.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
        peripheral.writeValue(Data(bytes), for: rx, type: type)
    }

    private func sendHandshakeIfReady() {
        guard !handshakeSent, syncRx != nil, asyncReady, syncTxReady || !hasSyncTx else { return }
        handshakeSent = true
        write(ZwiftClickProtocol.rideOn)
        manager?.updateState(role, .connected, detail: "Handshake…")
        handshakeTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, let self else { return }
            self.manager?.updateState(self.role, .connected, detail: "Keine Antwort auf Handshake – Tasten testen")
        }
        if isV2 { startKeepAlive() }
    }

    /// The Click v2 halves sleep after about a minute without traffic.
    private func startKeepAlive() {
        guard keepAliveTask == nil else { return }
        keepAliveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled, let self else { return }
                self.write(ZwiftClickProtocol.rideOn)
            }
        }
    }

    override func handle(_ value: [UInt8], from c: CBCharacteristic) {
        if c.uuid == BLEUUID.batteryLevel {
            super.handle(value, from: c)
            return
        }
        guard let message = ZwiftClickProtocol.decode(value) else { return }
        switch message {
        case let .handshake(encrypted):
            handshakeTimeout?.cancel()
            if encrypted, !isV2 {
                manager?.updateState(role, .failed("Verschlüsselt"), detail: "Click-Firmware über Zwift Companion aktualisieren")
                return
            }
            if !handshakeDone, isV2 { write(ZwiftClickProtocol.unlockAck) }
            handshakeDone = true
            manager?.updateState(role, .ready, detail: readyDetail)
        case .locked:
            // Only the handshake answer counts; the keep-alive echo can look different.
            guard c.uuid == BLEUUID.zwiftSyncTx, !handshakeDone else { return }
            handshakeTimeout?.cancel()
            if pod == .v1 { pod = role == .clickLeft ? .left : .right }
            manager?.updateState(role, .connected, detail: "Gesperrt – einmal kurz mit der Zwift-App verbinden (gilt ca. 24 h)")
            startKeepAlive()
        case let .buttons(state):
            markReady()
            var keys: Set<ClickButtonKey> = []
            if state.plus { keys.insert(.v1Plus) }
            if state.minus { keys.insert(.v1Minus) }
            manager?.clickButtons(from: peripheral.identifier, pressed: keys)
        case let .buttonMap(map):
            if pod == .v1 { pod = role == .clickLeft ? .left : .right }
            markReady()
            let keys = Set(mapTracker.pressed(map).map { ClickButtonKey(pod: pod, id: $0) })
            manager?.clickButtons(from: peripheral.identifier, pressed: keys)
        case let .battery(level):
            manager?.updateBattery(role, level)
        case .keepAlive, .other:
            break
        }
    }

    private func markReady() {
        handshakeTimeout?.cancel()
        handshakeDone = true
        if manager?.status[role]?.state != .ready || manager?.status[role]?.detail != readyDetail {
            manager?.updateState(role, .ready, detail: readyDetail)
        }
    }
}

// MARK: - Heart rate

@MainActor
final class HeartRateHandler: PeripheralHandler {
    override var serviceUUIDs: [CBUUID]? { [BLEUUID.heartRateService, BLEUUID.batteryService] }

    override func configure(_ c: CBCharacteristic) {
        if c.uuid == BLEUUID.heartRateMeasurement {
            peripheral.setNotifyValue(true, for: c)
        } else {
            super.configure(c)
        }
    }

    override func notificationsEnabled(for c: CBCharacteristic) {
        if c.uuid == BLEUUID.heartRateMeasurement { manager?.updateState(.heartRate, .ready) }
    }

    override func handle(_ value: [UInt8], from c: CBCharacteristic) {
        if c.uuid == BLEUUID.heartRateMeasurement {
            if let bpm = HeartRateParser.parse(value), bpm > 0 { manager?.updateHeartRate(bpm) }
        } else {
            super.handle(value, from: c)
        }
    }
}

// MARK: - Cadence sensor

@MainActor
final class CadenceHandler: PeripheralHandler {
    private var calculator = CrankCadenceCalculator()

    override var serviceUUIDs: [CBUUID]? { [BLEUUID.cscService, BLEUUID.batteryService] }

    override func configure(_ c: CBCharacteristic) {
        if c.uuid == BLEUUID.cscMeasurement {
            peripheral.setNotifyValue(true, for: c)
        } else {
            super.configure(c)
        }
    }

    override func notificationsEnabled(for c: CBCharacteristic) {
        if c.uuid == BLEUUID.cscMeasurement { manager?.updateState(.cadence, .ready) }
    }

    override func handle(_ value: [UInt8], from c: CBCharacteristic) {
        if c.uuid == BLEUUID.cscMeasurement {
            if let rpm = calculator.update(value, now: ProcessInfo.processInfo.systemUptime) {
                manager?.updatePedalCadence(rpm)
            }
        } else {
            super.handle(value, from: c)
        }
    }
}
