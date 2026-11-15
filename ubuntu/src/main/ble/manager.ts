// Pairs devices to roles, reconnects them and speaks FTMS / Zwift Click / heart rate / cadence.
import { ShiftDirection } from "../../core/basics";
import {
  BLEUUID,
  ButtonMapTracker,
  ClickButtonKey,
  ClickInputRouter,
  ClickKey,
  ClickPod,
  CrankCadenceCalculator,
  DeviceClassifier,
  DeviceRole,
  FTMSCommand,
  FTMSFeatures,
  IndoorBikeData,
  LiveSensors,
  PowerRange,
  TrainerCommand,
  ZwiftClickProtocol,
  ZwiftDeviceType,
  clickPodTitle,
  deviceRoles,
  isClickRole,
  isOptionalExtra,
  neutralCommand,
  parseFTMSFeatures,
  parseHeartRate,
  parseIndoorBikeData,
  parsePowerRange,
} from "../../core/ble";
import { SplitMix64 } from "../../core/elevation";
import { AdapterState, AppState, ConnectionState, DeviceStatus, DiscoveredDevice, Settings, emptyStatus, trainerRatioOf } from "../../core/state";
import { Advertisement, BleTransport, Characteristic } from "./bluez";

interface TrainerDevice {
  send(command: TrainerCommand): void;
}

interface SettingsAccess {
  get(): Settings;
  set(patch: Partial<Settings>): void;
}

// MARK: - Peripheral handlers

/** Base class: subscribes to characteristics and routes their values. */
abstract class PeripheralHandler {
  protected timers: ReturnType<typeof setTimeout>[] = [];
  protected closed = false;

  constructor(
    readonly role: DeviceRole,
    readonly id: string,
    readonly name: string | null,
    protected readonly manager: BLEManager,
    protected readonly transport: BleTransport,
    protected readonly characteristics: Characteristic[],
  ) {}

  protected has(uuid: string): boolean {
    return this.characteristics.some((c) => c.uuid === uuid);
  }

  protected flags(uuid: string): string[] {
    return this.characteristics.find((c) => c.uuid === uuid)?.flags ?? [];
  }

  protected async subscribe(uuid: string): Promise<boolean> {
    if (!this.has(uuid)) return false;
    try {
      await this.transport.subscribe(this.id, uuid);
      return !this.closed;
    } catch (error) {
      console.error(`Bluetooth: Benachrichtigungen für ${uuid} fehlgeschlagen:`, (error as Error).message);
      return false;
    }
  }

  protected async read(uuid: string): Promise<Uint8Array | null> {
    if (!this.has(uuid)) return null;
    try {
      return await this.transport.read(this.id, uuid);
    } catch {
      return null;
    }
  }

  protected write(uuid: string, bytes: number[], withResponse: boolean): void {
    if (this.closed) return;
    this.transport.write(this.id, uuid, bytes, withResponse).catch((error) => {
      console.error(`Bluetooth: Schreiben auf ${uuid} fehlgeschlagen:`, (error as Error).message);
    });
  }

  protected later(ms: number, action: () => void): ReturnType<typeof setTimeout> {
    const timer = setTimeout(() => {
      if (!this.closed) action();
    }, ms);
    this.timers.push(timer);
    return timer;
  }

  protected async setupBattery(): Promise<void> {
    const value = await this.read(BLEUUID.batteryLevel);
    if (value && value.length > 0) this.manager.updateBattery(this.role, value[0]);
    if (this.flags(BLEUUID.batteryLevel).includes("notify")) await this.subscribe(BLEUUID.batteryLevel);
  }

  abstract start(): Promise<void>;

  handle(uuid: string, value: Uint8Array): void {
    if (uuid === BLEUUID.batteryLevel && value.length > 0) this.manager.updateBattery(this.role, value[0]);
  }

  cleanup(): void {
    this.closed = true;
    for (const timer of this.timers) clearTimeout(timer);
    this.timers = [];
  }
}

/** Trainer (FTMS). */
class FTMSTrainerHandler extends PeripheralHandler implements TrainerDevice {
  isReady = false;
  features: FTMSFeatures = { supportsPowerTarget: true, supportsSimulation: true };
  private powerRange: PowerRange | null = null;
  private hasControl = false;
  private controlQueue: number[][] = [];
  private pendingSetting: TrainerCommand | null = null;
  private awaitingSince: number | null = null;
  private retryTimer: ReturnType<typeof setTimeout> | null = null;
  /** Last resistance command, sent again after the trainer gave control back (reset, sleep, reconnect). */
  private lastSetting: TrainerCommand | null = null;

  async start(): Promise<void> {
    const model = DeviceClassifier.trainerModel(this.name ?? "");
    if (!this.has(BLEUUID.ftmsControlPoint)) {
      this.manager.updateState("trainer", "failed", "Trainer-Firmware aktualisieren (Wahoo-App)", "Kein FTMS");
      return;
    }
    if (model) this.manager.updateState("trainer", "connected", `${model} · übernehme Steuerung…`);
    await this.subscribe(BLEUUID.indoorBikeData);
    await this.subscribe(BLEUUID.ftmsStatus);
    const features = await this.read(BLEUUID.fitnessMachineFeature);
    const parsed = features ? parseFTMSFeatures(features) : null;
    if (parsed) {
      this.features = parsed;
      this.manager.trainerCapabilitiesChanged();
    }
    const range = await this.read(BLEUUID.supportedPowerRange);
    if (range) this.powerRange = parsePowerRange(range);
    this.setupBattery();
    if (await this.subscribe(BLEUUID.ftmsControlPoint)) this.takeControl();
  }

  cleanup(): void {
    super.cleanup();
    if (this.retryTimer) clearTimeout(this.retryTimer);
    this.isReady = false;
  }

  private takeControl(): void {
    this.hasControl = false;
    this.isReady = false;
    this.controlQueue = [FTMSCommand.requestControl, FTMSCommand.start];
    this.awaitingSince = null;
    this.pump();
  }

  handle(uuid: string, value: Uint8Array): void {
    switch (uuid) {
      case BLEUUID.indoorBikeData: {
        const data = parseIndoorBikeData(value);
        if (data) this.manager.updateTrainer(data);
        break;
      }
      case BLEUUID.ftmsControlPoint:
        this.handleResponse(value);
        break;
      case BLEUUID.ftmsStatus:
        if (value.length === 0) return;
        if (value[0] === 0x01 || value[0] === 0xff) {
          // Reset or control permission lost: ask for control again.
          this.takeControl();
        } else if ((value[0] === 0x02 || value[0] === 0x04) && this.isReady) {
          // Stopped by the user or by safety key: start again so the next command is accepted.
          this.controlQueue.push(FTMSCommand.start);
          this.pump();
        }
        break;
      default:
        super.handle(uuid, value);
    }
  }

  private handleResponse(value: Uint8Array): void {
    const response = FTMSCommand.parseResponse(value);
    if (!response) return;
    this.awaitingSince = null;
    if (response.result === 0x05) {
      // control not permitted
      this.takeControl();
      return;
    }
    if (response.opcode === 0x00) this.hasControl = response.result === 0x01;
    if (response.opcode === 0x07 && this.hasControl && !this.isReady) {
      this.isReady = true;
      if (!this.pendingSetting) this.pendingSetting = this.lastSetting;
      this.manager.trainerBecameReady(this);
    }
    this.pump();
  }

  send(command: TrainerCommand): void {
    if (command.kind === "erg" && this.powerRange) {
      command = { kind: "erg", watts: Math.min(this.powerRange.maximum, Math.max(this.powerRange.minimum, command.watts)) };
    }
    this.pendingSetting = command;
    this.lastSetting = command;
    this.pump();
  }

  private pump(): void {
    if (this.closed) return;
    if (this.awaitingSince != null && Date.now() - this.awaitingSince < 2000) return;
    let bytes: number[];
    if (this.controlQueue.length > 0) {
      bytes = this.controlQueue.shift()!;
    } else if (this.isReady && this.pendingSetting) {
      bytes = FTMSCommand.encode(this.pendingSetting);
      this.pendingSetting = null;
    } else {
      return;
    }
    this.awaitingSince = Date.now();
    this.write(BLEUUID.ftmsControlPoint, bytes, true);
    if (this.retryTimer) clearTimeout(this.retryTimer);
    this.retryTimer = setTimeout(() => this.pump(), 2100);
  }
}

/**
 * Original Zwift Click and both halves of the Click v2.
 *
 * The Click v2 is two devices that speak the Zwift Ride protocol: the Zwift characteristics sit
 * under service FC82, buttons arrive as an inverted bit map (message 0x23), and each half goes
 * to sleep after about a minute without traffic, so the app repeats "RideOn" every few seconds.
 */
class ZwiftClickHandler extends PeripheralHandler {
  private handshakeDone = false;
  private mapTracker = new ButtonMapTracker();
  private handshakeTimeout: ReturnType<typeof setTimeout> | null = null;
  private keepAlive: ReturnType<typeof setInterval> | null = null;
  /** Set from the advertisement or detected from the services / messages. */
  pod: ClickPod;

  constructor(role: DeviceRole, id: string, name: string | null, manager: BLEManager, transport: BleTransport, characteristics: Characteristic[], pod: ClickPod | null) {
    super(role, id, name, manager, transport, characteristics);
    this.pod = pod ?? (role === "clickLeft" ? "left" : "v1");
  }

  private get isV2(): boolean {
    return this.pod !== "v1";
  }

  private get readyDetail(): string {
    if (this.pod === "right") return "Bereit · Click v2 rechts (+)";
    if (this.pod === "left") return "Bereit · Click v2 links (−)";
    return "Bereit";
  }

  async start(): Promise<void> {
    // Characteristics under FC82: this is a Click v2 half.
    if (this.pod === "v1" && this.characteristics.some((c) => c.service === BLEUUID.zwiftAdvertised)) {
      this.pod = this.role === "clickLeft" ? "left" : "right";
    }
    if (!this.has(BLEUUID.zwiftSyncRx)) {
      this.manager.updateState(this.role, "failed", null, "Unbekanntes Gerät");
      return;
    }
    const asyncReady = await this.subscribe(BLEUUID.zwiftAsync);
    if (this.has(BLEUUID.zwiftSyncTx)) await this.subscribe(BLEUUID.zwiftSyncTx);
    this.setupBattery();
    if (!asyncReady || this.closed) return;
    this.send(ZwiftClickProtocol.rideOn);
    this.manager.updateState(this.role, "connected", "Handshake…");
    this.handshakeTimeout = this.later(4000, () => {
      this.manager.updateState(this.role, "connected", "Keine Antwort auf Handshake – Tasten testen");
    });
    if (this.isV2) this.startKeepAlive();
  }

  cleanup(): void {
    super.cleanup();
    if (this.keepAlive) clearInterval(this.keepAlive);
    this.manager.clickButtons(this.id, null);
  }

  private send(bytes: number[]): void {
    const withoutResponse = this.flags(BLEUUID.zwiftSyncRx).includes("write-without-response");
    this.write(BLEUUID.zwiftSyncRx, bytes, !withoutResponse);
  }

  private cancelHandshakeTimeout(): void {
    if (this.handshakeTimeout) clearTimeout(this.handshakeTimeout);
    this.handshakeTimeout = null;
  }

  /** The Click v2 halves sleep after about a minute without traffic. */
  private startKeepAlive(): void {
    if (this.keepAlive) return;
    this.keepAlive = setInterval(() => this.send(ZwiftClickProtocol.rideOn), 3000);
  }

  handle(uuid: string, value: Uint8Array): void {
    if (uuid === BLEUUID.batteryLevel) {
      super.handle(uuid, value);
      return;
    }
    const message = ZwiftClickProtocol.decode(value);
    if (!message) return;
    const detectV2 = () => {
      if (this.pod === "v1") this.pod = this.role === "clickLeft" ? "left" : "right";
    };
    switch (message.kind) {
      case "handshake":
        this.cancelHandshakeTimeout();
        if (message.encrypted && !this.isV2) {
          this.manager.updateState(this.role, "failed", "Click-Firmware über Zwift Companion aktualisieren", "Verschlüsselt");
          return;
        }
        if (!this.handshakeDone && this.isV2) this.send(ZwiftClickProtocol.unlockAck);
        this.handshakeDone = true;
        this.manager.updateState(this.role, "ready", this.readyDetail);
        break;
      case "locked":
        // Only the handshake answer counts; the keep-alive echo can look different.
        if (uuid !== BLEUUID.zwiftSyncTx || this.handshakeDone) return;
        this.cancelHandshakeTimeout();
        detectV2();
        this.manager.updateState(this.role, "connected", "Gesperrt – einmal kurz mit der Zwift-App verbinden (gilt ca. 24 h)");
        this.startKeepAlive();
        break;
      case "buttons": {
        this.markReady();
        const keys = new Set<ClickButtonKey>();
        if (message.buttons.plus) keys.add(ClickKey.v1Plus);
        if (message.buttons.minus) keys.add(ClickKey.v1Minus);
        this.manager.clickButtons(this.id, keys);
        break;
      }
      case "buttonMap": {
        detectV2();
        this.markReady();
        const keys = new Set(this.mapTracker.pressed(message.map).map((bit) => ClickKey.make(this.pod, bit)));
        this.manager.clickButtons(this.id, keys);
        break;
      }
      case "battery":
        this.manager.updateBattery(this.role, message.level);
        break;
      default:
        break;
    }
  }

  private markReady(): void {
    this.cancelHandshakeTimeout();
    this.handshakeDone = true;
    const status = this.manager.status[this.role];
    if (status.state !== "ready" || status.detail !== this.readyDetail) this.manager.updateState(this.role, "ready", this.readyDetail);
  }
}

class HeartRateHandler extends PeripheralHandler {
  async start(): Promise<void> {
    if (await this.subscribe(BLEUUID.heartRateMeasurement)) this.manager.updateState("heartRate", "ready");
    this.setupBattery();
  }

  handle(uuid: string, value: Uint8Array): void {
    if (uuid === BLEUUID.heartRateMeasurement) {
      const bpm = parseHeartRate(value);
      if (bpm != null && bpm > 0) this.manager.updateHeartRate(bpm);
    } else {
      super.handle(uuid, value);
    }
  }
}

class CadenceHandler extends PeripheralHandler {
  private calculator = new CrankCadenceCalculator();

  async start(): Promise<void> {
    if (await this.subscribe(BLEUUID.cscMeasurement)) this.manager.updateState("cadence", "ready");
    this.setupBattery();
  }

  handle(uuid: string, value: Uint8Array): void {
    if (uuid === BLEUUID.cscMeasurement) {
      const rpm = this.calculator.update(value, performance.now() / 1000);
      if (rpm != null) this.manager.updatePedalCadence(rpm);
    } else {
      super.handle(uuid, value);
    }
  }
}

// MARK: - Demo trainer

/**
 * Simulated trainer, heart rate and cadence for trying the app without hardware.
 *
 * The simulated rider aims for a slowly changing effort and adapts cadence to the
 * resistance, so harder gears lower the cadence and climbs feel heavier.
 */
class DemoTrainer implements TrainerDevice {
  private timer: ReturnType<typeof setInterval> | null = null;
  private mode: TrainerCommand = neutralCommand;
  private t = 0;
  private cadence = 85;
  private power = 0;
  private heartRate = 92;
  private rng = new SplitMix64(42);

  constructor(
    private readonly manager: BLEManager,
    private readonly settings: SettingsAccess,
  ) {}

  start(): void {
    this.stop();
    this.timer = setInterval(() => this.step(0.25), 250);
  }

  stop(): void {
    if (this.timer) clearInterval(this.timer);
    this.timer = null;
  }

  send(command: TrainerCommand): void {
    this.mode = command;
  }

  private noise(amount: number): number {
    return (this.rng.unit() - 0.5) * 2 * amount;
  }

  private step(dt: number): void {
    this.t += dt;
    const s = this.settings.get();
    const ratio = trainerRatioOf(s);
    const circumference = 2.096;
    const mass = s.riderWeight + s.bikeWeight;
    const effort = 215 + 35 * Math.sin(this.t / 47) + 20 * Math.sin(this.t / 13);
    const mode = this.mode;

    if (mode.kind === "erg") {
      this.power += (mode.watts - this.power) * 0.3 + this.noise(4);
      this.cadence += (88 - this.cadence) * 0.1 + this.noise(0.6);
    } else {
      const powerAt = (rpm: number) => {
        const v = (rpm / 60) * ratio * circumference;
        const theta = Math.atan(mode.gradePercent / 100);
        return (mass * 9.81 * (mode.crr * Math.cos(theta) + Math.sin(theta)) + 0.5 * mode.windResistance * v * v) * v;
      };
      let lo = 40;
      let hi = 125;
      let target: number;
      if (powerAt(hi) < effort) {
        target = 110;
      } else if (powerAt(lo) > effort) {
        target = 55;
      } else {
        for (let i = 0; i < 30; i++) {
          const mid = (lo + hi) / 2;
          if (powerAt(mid) < effort) lo = mid;
          else hi = mid;
        }
        target = Math.min(110, Math.max(55, lo));
      }
      this.cadence += (target - this.cadence) * 0.25 + this.noise(0.5);
      this.power = Math.max(0, powerAt(this.cadence)) + this.noise(5);
    }

    this.heartRate += (92 + 0.3 * this.power - this.heartRate) * 0.02;
    const speed = (this.cadence / 60) * ratio * circumference;
    this.manager.updateTrainer({ speedKmh: speed * 3.6, cadence: this.cadence, power: Math.round(this.power) });
    this.manager.updateHeartRate(Math.round(this.heartRate));
    this.manager.updatePedalCadence(this.cadence);
  }
}

// MARK: - Manager

/** Owns the Bluetooth connection: scanning, pairing devices to roles, reconnecting. */
export class BLEManager {
  adapter: AdapterState = "unknown";
  adapterMessage: string | null = null;
  isScanning = false;
  discovered: DiscoveredDevice[] = [];
  status: Record<DeviceRole, DeviceStatus>;
  live = new LiveSensors();

  onShift: ((direction: ShiftDirection) => void) | null = null;
  /** Both Click buttons pressed together. */
  onBothButtons: (() => void) | null = null;
  /** The trainer (re)gained control, e.g. after a reconnect: resend the current resistance. */
  onTrainerReady: (() => void) | null = null;
  /** Something the windows show has changed. */
  onChange: () => void = () => undefined;

  /** Button learning in the devices sheet: which direction is asked for next. */
  learningDirection: ShiftDirection | null = null;
  /** Last button seen while learning (shown as feedback). */
  learnedSummary: string | null = null;

  readonly clickInput: ClickInputRouter;
  private trainer: TrainerDevice | null = null;
  private handlers = new Map<string, PeripheralHandler>();
  private zwiftTypes = new Map<string, number>();
  private demo: DemoTrainer | null = null;
  private scanTimer: ReturnType<typeof setTimeout> | null = null;
  private started = false;

  constructor(
    private readonly settings: SettingsAccess,
    private readonly transport: BleTransport,
  ) {
    this.clickInput = new ClickInputRouter(() => settings.get().clickButtonMap);
    this.clickInput.onShift = (direction) => this.onShift?.(direction);
    this.clickInput.onBothButtons = () => this.onBothButtons?.();
    this.status = Object.fromEntries(deviceRoles.map((role) => [role, emptyStatus(this.assignedId(role) ? "searching" : "notAssigned")])) as Record<
      DeviceRole,
      DeviceStatus
    >;
  }

  /** Roles shown in device lists: the Click v2 left half only once it is known. */
  get visibleRoles(): DeviceRole[] {
    return deviceRoles.filter(
      (role) => !isOptionalExtra(role) || this.status[role].state !== "notAssigned" || this.discovered.some((d) => d.roles.includes(role)),
    );
  }

  snapshot(): AppState["ble"] {
    return {
      adapter: this.adapter,
      adapterMessage: this.adapterMessage,
      isScanning: this.isScanning,
      isDemo: this.isDemo,
      discovered: this.discovered,
      status: this.status,
      visibleRoles: this.visibleRoles,
      learningDirection: this.learningDirection,
      learnedSummary: this.learnedSummary,
    };
  }

  start(): void {
    if (this.settings.get().demoMode) this.startDemo();
    if (this.started) return;
    this.started = true;
    void this.transport.start({
      adapterState: (state, message) => this.adapterChanged(state, message),
      discovered: (ad) => this.didDiscover(ad),
      connected: (id, name, characteristics) => this.didConnect(id, name, characteristics),
      disconnected: (id) => this.didDisconnect(id),
      value: (id, uuid, bytes) => this.handlers.get(id)?.handle(uuid, bytes),
      scanning: () => undefined,
    });
  }

  // MARK: Demo

  get isDemo(): boolean {
    return this.demo != null;
  }

  setDemoMode(enabled: boolean): void {
    this.settings.set({ demoMode: enabled });
    if (enabled) this.startDemo();
    else this.stopDemo();
    this.onChange();
  }

  /** Demo for this launch only, without changing the saved setting. */
  startTemporaryDemo(): void {
    this.startDemo();
    this.onChange();
  }

  private startDemo(): void {
    if (this.demo) return;
    const demo = new DemoTrainer(this, this.settings);
    this.demo = demo;
    this.trainer = demo;
    demo.start();
    for (const role of ["trainer", "heartRate", "cadence"] as DeviceRole[]) {
      const id = this.assignedId(role);
      if (id) this.disconnect(id);
      this.status[role] = { ...emptyStatus("ready"), name: "Demo", detail: "Simuliert" };
    }
  }

  private stopDemo(): void {
    this.demo?.stop();
    this.demo = null;
    this.trainer = null;
    this.live = new LiveSensors();
    for (const role of ["trainer", "heartRate", "cadence"] as DeviceRole[]) {
      this.status[role] = emptyStatus(this.assignedId(role) ? "searching" : "notAssigned");
    }
    this.reconnectAssigned();
  }

  // MARK: Commands

  send(command: TrainerCommand): void {
    this.trainer?.send(command);
  }

  /** False when the trainer says it cannot simulate slopes; gears then use ERG. */
  get trainerSupportsSimulation(): boolean {
    return this.trainer instanceof FTMSTrainerHandler ? this.trainer.features.supportsSimulation : true;
  }

  /** True when power or cadence data arrived recently, so pedalling can be detected. */
  hasMotionData(now: number): boolean {
    return this.live.power(now) != null || this.live.cadence(now) != null;
  }

  // MARK: Scanning and pairing

  startScan(durationSeconds = 30): void {
    if (this.adapter !== "poweredOn") return;
    this.transport.setUserScan(true);
    this.isScanning = true;
    if (this.scanTimer) clearTimeout(this.scanTimer);
    this.scanTimer = setTimeout(() => this.stopScan(), durationSeconds * 1000);
    this.onChange();
  }

  stopScan(): void {
    if (this.scanTimer) clearTimeout(this.scanTimer);
    this.scanTimer = null;
    this.transport.setUserScan(false);
    this.isScanning = false;
    this.onChange();
  }

  assign(deviceId: string, role: DeviceRole): void {
    const device = this.discovered.find((d) => d.id === deviceId);
    // A device can only hold one role.
    for (const other of deviceRoles) {
      if (other !== role && this.assignedId(other) === deviceId) this.unassign(other);
    }
    const old = this.assignedId(role);
    if (old && old !== deviceId) this.disconnect(old);
    this.settings.set({ assignedDevices: { ...this.settings.get().assignedDevices, [role]: deviceId } });
    this.status[role] = { ...emptyStatus("connecting"), name: device?.name ?? null };
    this.transport.want(deviceId);
    this.onChange();
  }

  unassign(role: DeviceRole): void {
    const id = this.assignedId(role);
    if (id) this.disconnect(id);
    const assigned = { ...this.settings.get().assignedDevices };
    delete assigned[role];
    this.settings.set({ assignedDevices: assigned });
    this.status[role] = emptyStatus("notAssigned");
    this.onChange();
  }

  assignedId(role: DeviceRole): string | null {
    return this.settings.get().assignedDevices[role] ?? null;
  }

  private roleFor(id: string): DeviceRole | null {
    return deviceRoles.find((role) => this.assignedId(role) === id) ?? null;
  }

  private skippedInDemo(role: DeviceRole): boolean {
    return this.isDemo && !isClickRole(role);
  }

  private disconnect(id: string): void {
    this.handlers.get(id)?.cleanup();
    this.handlers.delete(id);
    this.transport.release(id);
  }

  private reconnectAssigned(): void {
    if (this.adapter !== "poweredOn") return;
    for (const role of deviceRoles) {
      if (this.skippedInDemo(role)) continue;
      const id = this.assignedId(role);
      if (!id) continue;
      if (!this.handlers.has(id)) this.status[role] = { ...this.status[role], state: "searching", message: null };
      this.transport.want(id);
    }
    // Roles without a device: look for one for a while.
    if (deviceRoles.some((role) => !isOptionalExtra(role) && !this.skippedInDemo(role) && !this.assignedId(role))) this.startScan();
    this.onChange();
  }

  // MARK: Transport events

  private adapterChanged(state: AdapterState, message: string | null): void {
    this.adapter = state;
    this.adapterMessage = message;
    if (state === "poweredOn") {
      this.reconnectAssigned();
    } else {
      for (const role of deviceRoles) {
        if (this.skippedInDemo(role)) continue;
        if (this.assignedId(role) || state === "poweredOff") {
          this.status[role] = { ...this.status[role], state: "failed", message: state === "poweredOff" ? "Bluetooth aus" : "Kein Bluetooth" };
        }
      }
    }
    this.onChange();
  }

  private didDiscover(ad: Advertisement): void {
    const roles = DeviceClassifier.roles(ad.name, ad.services, ad.manufacturerData);
    if (roles.length === 0) return;
    const type = DeviceClassifier.zwiftDeviceType(ad.manufacturerData);
    if (type != null) this.zwiftTypes.set(ad.id, type);
    const device: DiscoveredDevice = { id: ad.id, name: ad.name, rssi: ad.rssi, roles };
    const index = this.discovered.findIndex((d) => d.id === ad.id);
    if (index >= 0) this.discovered[index] = device;
    else this.discovered.push(device);

    const known = this.roleFor(ad.id);
    if (known) {
      // Known device found again: the transport is already connecting.
      if (!this.handlers.has(ad.id) && this.status[known].state === "searching") {
        this.status[known] = { ...emptyStatus("connecting"), name: ad.name };
      }
    } else {
      // First device of a role that has none yet: pair automatically.
      for (const role of roles) {
        if (this.assignedId(role) || this.skippedInDemo(role)) continue;
        this.assign(ad.id, role);
        break;
      }
    }
    this.onChange();
  }

  private didConnect(id: string, name: string | null, characteristics: Characteristic[]): void {
    const role = this.roleFor(id);
    if (!role || this.skippedInDemo(role)) {
      this.transport.release(id);
      return;
    }
    this.handlers.get(id)?.cleanup();
    let handler: PeripheralHandler;
    switch (role) {
      case "trainer":
        handler = new FTMSTrainerHandler(role, id, name, this, this.transport, characteristics);
        break;
      case "click":
      case "clickLeft":
        handler = new ZwiftClickHandler(role, id, name, this, this.transport, characteristics, ZwiftDeviceType.pod(this.zwiftTypes.get(id)));
        break;
      case "heartRate":
        handler = new HeartRateHandler(role, id, name, this, this.transport, characteristics);
        break;
      case "cadence":
        handler = new CadenceHandler(role, id, name, this, this.transport, characteristics);
        break;
    }
    this.handlers.set(id, handler);
    this.status[role] = { ...emptyStatus("connected"), name: name ?? this.status[role].name, battery: this.status[role].battery };
    this.onChange();
    handler.start().catch((error) => console.error("Bluetooth:", error));
  }

  private didDisconnect(id: string): void {
    const handler = this.handlers.get(id);
    handler?.cleanup();
    this.handlers.delete(id);
    if (handler && (handler as unknown) === this.trainer) this.trainer = this.demo;
    const role = this.roleFor(id);
    if (role) this.status[role] = { ...this.status[role], state: "connecting", message: null, detail: null };
    this.onChange();
  }

  // MARK: Updates from handlers

  updateTrainer(data: IndoorBikeData): void {
    if (data.power != null) this.live.trainerPower = data.power;
    if (data.cadence != null) this.live.trainerCadence = data.cadence;
    if (data.speedKmh != null) this.live.trainerSpeedValue = data.speedKmh / 3.6;
    this.live.trainerUpdated = Date.now();
  }

  updateHeartRate(bpm: number): void {
    this.live.heartRateValue = bpm;
    this.live.heartRateUpdated = Date.now();
  }

  updatePedalCadence(rpm: number): void {
    this.live.pedalCadence = rpm;
    this.live.pedalUpdated = Date.now();
  }

  updateBattery(role: DeviceRole, level: number): void {
    if (this.status[role].battery === level) return;
    this.status[role] = { ...this.status[role], battery: level };
    this.onChange();
  }

  updateState(role: DeviceRole, state: ConnectionState, detail?: string | null, message?: string): void {
    this.status[role] = { ...this.status[role], state, message: message ?? null, detail: detail !== undefined ? detail : this.status[role].detail };
    this.onChange();
  }

  /** Pressed buttons of one controller; null when it disconnected. */
  clickButtons(source: string, pressed: Set<ClickButtonKey> | null): void {
    if (pressed) this.clickInput.update(source, pressed);
    else this.clickInput.remove(source);
  }

  trainerBecameReady(handler: FTMSTrainerHandler): void {
    if (!this.demo) this.trainer = handler;
    const model = DeviceClassifier.trainerModel(handler.name ?? "");
    this.updateState("trainer", "ready", model ? `Bereit · ${model}` : "Bereit");
    this.onTrainerReady?.();
  }

  trainerCapabilitiesChanged(): void {
    this.onTrainerReady?.();
  }

  // MARK: Click button learning

  /** Starts learning: the rider presses the button for "schwerer", then for "leichter". */
  startLearningButtons(): void {
    this.learnedSummary = null;
    const learned: Record<string, string> = {};
    this.learningDirection = "up";
    this.clickInput.onLearn = (key) => {
      const direction = this.learningDirection;
      if (!direction) return;
      const pod = ClickKey.pod(key);
      if (pod === "v1" || !pod) {
        this.learnedSummary = "Der Click (v1) braucht keine Zuordnung.";
        this.stopLearningButtons();
        return;
      }
      learned[key] = direction;
      if (direction === "up") {
        this.learnedSummary = `Schwerer: ${ClickKey.label(key)} der ${clickPodTitle[pod]}`;
        this.learningDirection = "down";
      } else {
        this.settings.set({ clickButtonMap: learned });
        this.learnedSummary = `Gespeichert. Leichter: ${ClickKey.label(key)} der ${clickPodTitle[pod]}`;
        this.stopLearningButtons();
      }
      this.onChange();
    };
    this.onChange();
  }

  stopLearningButtons(): void {
    this.learningDirection = null;
    this.clickInput.onLearn = null;
    this.onChange();
  }

  resetButtonMapping(): void {
    this.settings.set({ clickButtonMap: {} });
    this.learnedSummary = "Standard: rechte Hälfte schaltet schwerer, linke leichter.";
    this.onChange();
  }
}
