// Bluetooth protocols: FTMS, heart rate, cadence and the Zwift Click (v1 and v2). No I/O in here.
import { ShiftDirection, clamp, rnd } from "./basics";

const sig = (short: string) => `0000${short.toLowerCase()}-0000-1000-8000-00805f9b34fb`;

/** Lower-case 128-bit UUIDs, as BlueZ reports them. */
export const BLEUUID = {
  ftmsService: sig("1826"),
  indoorBikeData: sig("2ad2"),
  ftmsControlPoint: sig("2ad9"),
  ftmsStatus: sig("2ada"),
  cyclingPowerService: sig("1818"),
  heartRateService: sig("180d"),
  heartRateMeasurement: sig("2a37"),
  cscService: sig("1816"),
  cscMeasurement: sig("2a5b"),
  batteryService: sig("180f"),
  batteryLevel: sig("2a19"),
  zwiftService: "00000001-19ca-4651-86e5-fa29dcdd09d1",
  zwiftAsync: "00000002-19ca-4651-86e5-fa29dcdd09d1",
  zwiftSyncRx: "00000003-19ca-4651-86e5-fa29dcdd09d1",
  zwiftSyncTx: "00000004-19ca-4651-86e5-fa29dcdd09d1",
  /** Zwift's 16-bit service. Ride and Click v2 expose the Zwift characteristics under it. */
  zwiftAdvertised: sig("fc82"),
  fitnessMachineFeature: sig("2acc"),
  supportedPowerRange: sig("2ad8"),
  zwiftManufacturerId: 0x094a,
};

export type Bytes = ArrayLike<number>;

/** Little-endian reader for BLE characteristic values. */
export class ByteReader {
  offset = 0;
  constructor(private readonly bytes: Bytes) {}

  get remaining(): number {
    return this.bytes.length - this.offset;
  }

  u8(): number | null {
    if (this.remaining < 1) return null;
    return this.bytes[this.offset++];
  }

  u16(): number | null {
    if (this.remaining < 2) return null;
    const v = this.bytes[this.offset] | (this.bytes[this.offset + 1] << 8);
    this.offset += 2;
    return v;
  }

  s16(): number | null {
    const v = this.u16();
    return v == null ? null : v > 0x7fff ? v - 0x10000 : v;
  }

  u24(): number | null {
    if (this.remaining < 3) return null;
    const v = this.bytes[this.offset] | (this.bytes[this.offset + 1] << 8) | (this.bytes[this.offset + 2] << 16);
    this.offset += 3;
    return v;
  }

  u32(): number | null {
    if (this.remaining < 4) return null;
    const b = this.bytes;
    const o = this.offset;
    this.offset += 4;
    return b[o] + b[o + 1] * 256 + b[o + 2] * 65536 + b[o + 3] * 16777216;
  }

  skip(n: number): void {
    this.offset = Math.min(this.bytes.length, this.offset + n);
  }
}

// MARK: - Trainer commands

export type TrainerCommand =
  /** FTMS indoor bike simulation: grade in percent, rolling resistance coefficient, wind resistance in kg/m. */
  | { kind: "sim"; gradePercent: number; crr: number; windResistance: number }
  /** FTMS ERG target power. */
  | { kind: "erg"; watts: number };

export const neutralCommand: TrainerCommand = { kind: "sim", gradePercent: 0, crr: 0.004, windResistance: 0.38 };

export function commandsClose(a: TrainerCommand, b: TrainerCommand): boolean {
  if (a.kind === "sim" && b.kind === "sim") {
    return Math.abs(a.gradePercent - b.gradePercent) < 0.1 && Math.abs(a.crr - b.crr) < 0.0002 && Math.abs(a.windResistance - b.windResistance) < 0.01;
  }
  if (a.kind === "erg" && b.kind === "erg") return Math.abs(a.watts - b.watts) < 2;
  return false;
}

// MARK: - FTMS

/** One FTMS Indoor Bike Data notification. Only fields present in the packet are set. */
export interface IndoorBikeData {
  speedKmh?: number;
  cadence?: number;
  totalDistance?: number;
  resistance?: number;
  power?: number;
  heartRate?: number;
}

export function parseIndoorBikeData(bytes: Bytes): IndoorBikeData | null {
  const r = new ByteReader(bytes);
  const flags = r.u16();
  if (flags == null) return null;
  const d: IndoorBikeData = {};
  const set = <K extends keyof IndoorBikeData>(key: K, value: number | null, scale = 1) => {
    if (value != null) d[key] = value / scale;
  };
  if ((flags & 0x0001) === 0) set("speedKmh", r.u16(), 100);
  if (flags & 0x0002) r.skip(2);
  if (flags & 0x0004) set("cadence", r.u16(), 2);
  if (flags & 0x0008) r.skip(2);
  if (flags & 0x0010) set("totalDistance", r.u24());
  if (flags & 0x0020) set("resistance", r.s16());
  if (flags & 0x0040) set("power", r.s16());
  if (flags & 0x0080) r.skip(2);
  if (flags & 0x0100) r.skip(5);
  if (flags & 0x0200) set("heartRate", r.u8());
  return d;
}

const le16 = (v: number) => {
  const u = v < 0 ? v + 0x10000 : v;
  return [u & 0xff, (u >> 8) & 0xff];
};

export const FTMSCommand = {
  requestControl: [0x00],
  reset: [0x01],
  start: [0x07],

  encode(command: TrainerCommand): number[] {
    if (command.kind === "erg") return [0x05, ...le16(clamp(Math.trunc(command.watts), -32768, 32767))];
    const gradeRaw = clamp(rnd(command.gradePercent * 100), -32768, 32767);
    const crrRaw = clamp(rnd(command.crr * 10_000), 0, 255);
    const windRaw = clamp(rnd(command.windResistance * 100), 0, 255);
    return [0x11, ...le16(0), ...le16(gradeRaw), crrRaw, windRaw];
  },

  /** Parses a control point indication: (request opcode, result code). */
  parseResponse(bytes: Bytes): { opcode: number; result: number } | null {
    if (bytes.length < 3 || bytes[0] !== 0x80) return null;
    return { opcode: bytes[1], result: bytes[2] };
  },
};

/** What the trainer says it can do (Fitness Machine Feature characteristic). */
export interface FTMSFeatures {
  supportsPowerTarget: boolean;
  supportsSimulation: boolean;
}

export function parseFTMSFeatures(bytes: Bytes): FTMSFeatures | null {
  const r = new ByteReader(bytes);
  if (r.u32() == null) return null;
  const targets = r.u32();
  if (targets == null) return null;
  return { supportsPowerTarget: (targets & 0x0008) !== 0, supportsSimulation: (targets & 0x2000) !== 0 };
}

/** Supported Power Range: ERG targets outside it are clamped. */
export interface PowerRange {
  minimum: number;
  maximum: number;
}

export function parsePowerRange(bytes: Bytes): PowerRange | null {
  const r = new ByteReader(bytes);
  const lo = r.s16();
  const hi = r.s16();
  if (lo == null || hi == null || !(hi > lo) || !(hi > 0)) return null;
  return { minimum: Math.max(0, lo), maximum: hi };
}

// MARK: - Heart rate and cadence

export function parseHeartRate(bytes: Bytes): number | null {
  if (bytes.length < 2) return null;
  if ((bytes[0] & 0x01) === 0) return bytes[1];
  if (bytes.length < 3) return null;
  return bytes[1] | (bytes[2] << 8);
}

/** Cadence from a CSC (cycling speed and cadence) sensor, e.g. a pedal or crank sensor. */
export class CrankCadenceCalculator {
  private lastRevolutions: number | null = null;
  private lastEventTime: number | null = null;
  private lastChange = 0;
  cadence = 0;

  /** Feeds one CSC measurement. `now` is a monotonic time in seconds. */
  update(bytes: Bytes, now: number): number | null {
    const r = new ByteReader(bytes);
    const flags = r.u8();
    if (flags == null) return null;
    if (flags & 0x01) r.skip(6);
    if (!(flags & 0x02)) return null;
    const revs = r.u16();
    const time = r.u16();
    if (revs == null || time == null) return null;
    if (this.lastRevolutions != null && this.lastEventTime != null) {
      const dRev = (revs - this.lastRevolutions) & 0xffff;
      const dTime = (time - this.lastEventTime) & 0xffff;
      if (dRev > 0 && dTime > 0) {
        const rpm = (dRev * 60 * 1024) / dTime;
        if (rpm < 250) this.cadence = rpm;
        this.lastChange = now;
      } else if (now - this.lastChange > 2.5) {
        this.cadence = 0;
      }
    } else {
      this.lastChange = now;
    }
    this.lastRevolutions = revs;
    this.lastEventTime = time;
    return this.cadence;
  }
}

// MARK: - Zwift Click

/** Which Zwift controller a button belongs to: original Click, or right (+) / left (−) half of the Click v2. */
export type ClickPod = "v1" | "right" | "left";

export const clickPodTitle: Record<ClickPod, string> = { v1: "Click", right: "rechte Hälfte (+)", left: "linke Hälfte (−)" };

/** One physical button as "pod:id" (v1: 1 = plus, 2 = minus; v2: bit of the button map). */
export type ClickButtonKey = string;

export const ClickKey = {
  v1Plus: "v1:1",
  v1Minus: "v1:2",
  make(pod: ClickPod, id: number): ClickButtonKey {
    return `${pod}:${id >>> 0}`;
  },
  pod(key: ClickButtonKey): ClickPod | null {
    const pod = key.split(":")[0];
    return pod === "v1" || pod === "right" || pod === "left" ? pod : null;
  },
  /** "+", "−" or "Taste 13" (bit number of the Click v2 button map). */
  label(key: ClickButtonKey): string {
    if (key === ClickKey.v1Plus) return "+";
    if (key === ClickKey.v1Minus) return "−";
    const id = Number(key.split(":")[1]) >>> 0;
    let bit = 0;
    while (bit < 32 && ((id >>> bit) & 1) === 0) bit++;
    return `Taste ${bit + 1}`;
  },
};

export interface ClickButtons {
  plus: boolean;
  minus: boolean;
}

export type ClickMessage =
  | { kind: "handshake"; encrypted: boolean }
  /** Click v2 left pod that Zwift has not unlocked in the last ~24 h answers with a challenge. */
  | { kind: "locked" }
  | { kind: "buttons"; buttons: ClickButtons }
  /** Raw Ride/Click v2 button map (bit cleared = pressed). */
  | { kind: "buttonMap"; map: number }
  | { kind: "battery"; level: number }
  | { kind: "keepAlive" }
  | { kind: "other"; type: number };

const rideOn = Array.from("RideOn").map((c) => c.charCodeAt(0));

/** Minimal protobuf reader: returns all varint fields by field number. */
export function varintFields(bytes: Bytes): Map<number, bigint> {
  const result = new Map<number, bigint>();
  let i = 0;
  const readVarint = (): bigint | null => {
    let value = 0n;
    let shift = 0n;
    while (i < bytes.length) {
      const b = bytes[i];
      i += 1;
      value |= BigInt(b & 0x7f) << shift;
      if ((b & 0x80) === 0) return value;
      shift += 7n;
      if (shift > 63n) return null;
    }
    return null;
  };
  while (i < bytes.length) {
    const key = readVarint();
    if (key == null) break;
    const field = Number(key >> 3n);
    switch (Number(key & 7n)) {
      case 0: {
        const v = readVarint();
        if (v == null) return result;
        result.set(field, v);
        break;
      }
      case 1:
        i += 8;
        break;
      case 2: {
        const len = readVarint();
        if (len == null) return result;
        i += Number(len);
        break;
      }
      case 5:
        i += 4;
        break;
      default:
        return result;
    }
  }
  return result;
}

export const ZwiftClickProtocol = {
  rideOn,
  /** Click v1 button notification. */
  clickNotification: 0x37,
  /** Zwift Ride / Click v2 button map notification. */
  rideKeyPadNotification: 0x23,
  batteryNotification: 0x19,
  emptyMessage: 0x15,
  /** Written to the Click v2 after the handshake; keeps an unlocked left pod unlocked across reconnects. */
  unlockAck: [0xff, 0x04, 0x00],

  decode(bytes: Bytes): ClickMessage | null {
    if (bytes.length === 0) return null;
    const first = bytes[0];
    if (bytes.length >= rideOn.length && rideOn.every((c, i) => bytes[i] === c)) {
      // A plain response is "RideOn" plus two bytes; a long tail is a public key (encrypted mode).
      return { kind: "handshake", encrypted: bytes.length > rideOn.length + 8 };
    }
    const body = Array.prototype.slice.call(bytes, 1) as number[];
    switch (first) {
      case ZwiftClickProtocol.clickNotification: {
        const fields = varintFields(body);
        // Button status enum: 0 = pressed, 1 = released.
        return { kind: "buttons", buttons: { plus: fields.get(1) === 0n, minus: fields.get(2) === 0n } };
      }
      case ZwiftClickProtocol.rideKeyPadNotification: {
        const map = varintFields(body).get(1);
        if (map == null) return { kind: "other", type: first };
        return { kind: "buttonMap", map: Number(map & 0xffffffffn) };
      }
      case ZwiftClickProtocol.batteryNotification: {
        const fields = varintFields(body);
        const level = fields.get(1) ?? fields.get(2);
        return level != null ? { kind: "battery", level: Number(level) } : { kind: "other", type: first };
      }
      case ZwiftClickProtocol.emptyMessage:
        return { kind: "keepAlive" };
      case 0xff:
        return { kind: "locked" };
      default:
        return { kind: "other", type: first };
    }
  },
};

/**
 * Turns the Click v2 inverted button map into the set of pressed bits.
 *
 * Only bits that have been seen released at least once count, so unused bits that
 * are always 0 never look like a held button.
 */
export class ButtonMapTracker {
  knownButtons = 0;

  pressed(map: number): number[] {
    this.knownButtons = (this.knownButtons | map) >>> 0;
    const down = (this.knownButtons & ~map) >>> 0;
    const result: number[] = [];
    for (let bit = 0; bit < 32; bit++) {
      const mask = (1 << bit) >>> 0;
      if ((down & mask) !== 0) result.push(mask);
    }
    return result;
  }
}

export type ClickAction =
  | { kind: "shift"; direction: ShiftDirection }
  | { kind: "startRepeat"; direction: ShiftDirection }
  | { kind: "stopRepeat" }
  | { kind: "bothPressed" };

/** Turns Click button states into actions: one press shifts, both buttons together pause. */
export class ClickButtonInterpreter {
  buttons: ClickButtons = { plus: false, minus: false };
  private comboActive = false;

  isHeld(direction: ShiftDirection): boolean {
    return !this.comboActive && (direction === "up" ? this.buttons.plus : this.buttons.minus);
  }

  process(next: ClickButtons): ClickAction[] {
    const prev = this.buttons;
    this.buttons = { ...next };
    const bothNow = next.plus && next.minus;
    if (bothNow && !(prev.plus && prev.minus)) {
      this.comboActive = true;
      const actions: ClickAction[] = [{ kind: "stopRepeat" }];
      // The button pressed first already shifted: take that shift back.
      if (prev.plus) actions.push({ kind: "shift", direction: "down" });
      if (prev.minus) actions.push({ kind: "shift", direction: "up" });
      actions.push({ kind: "bothPressed" });
      return actions;
    }
    if (this.comboActive) {
      // Ignore everything until both buttons are released.
      if (!next.plus && !next.minus) this.comboActive = false;
      return [];
    }
    const actions: ClickAction[] = [];
    if (next.plus && !prev.plus) actions.push({ kind: "shift", direction: "up" }, { kind: "startRepeat", direction: "up" });
    if (next.minus && !prev.minus) actions.push({ kind: "shift", direction: "down" }, { kind: "startRepeat", direction: "down" });
    if (!next.plus && !next.minus && (prev.plus || prev.minus)) actions.push({ kind: "stopRepeat" });
    return actions;
  }
}

/**
 * Combines the buttons of all connected Zwift controllers into shift and pause actions.
 *
 * The original Click is one device with + and −. The Click v2 is two devices (right = +,
 * left = −), so "both buttons together" spans two connections and has to be judged here.
 */
export class ClickInputRouter {
  /** Pressed buttons per connected controller. */
  private pressed = new Map<string, Set<ClickButtonKey>>();
  private interpreter = new ClickButtonInterpreter();
  private repeatTimer: ReturnType<typeof setTimeout> | null = null;

  onShift: ((direction: ShiftDirection) => void) | null = null;
  onBothButtons: (() => void) | null = null;
  /** While set, the next pressed button is reported here instead of shifting. */
  onLearn: ((key: ClickButtonKey) => void) | null = null;

  /** `buttonMap` returns the learned assignments: "pod:bit" -> "up" / "down". */
  constructor(private readonly buttonMap: () => Record<string, string>) {}

  /** Direction of one button: learned mapping first, then the pod's natural side. */
  direction(key: ClickButtonKey): ShiftDirection | null {
    if (key === ClickKey.v1Plus) return "up";
    if (key === ClickKey.v1Minus) return "down";
    const mapping = this.buttonMap();
    const learned = mapping[key];
    if (learned) return learned === "up" ? "up" : "down";
    const pod = ClickKey.pod(key);
    // Once a pod has learned buttons, its other buttons stay unassigned.
    if (Object.keys(mapping).some((k) => ClickKey.pod(k) === pod)) return null;
    if (pod === "right") return "up";
    if (pod === "left") return "down";
    return null;
  }

  update(source: string, keys: Set<ClickButtonKey>): void {
    const previous = this.pressed.get(source) ?? new Set<ClickButtonKey>();
    this.pressed.set(source, keys);
    if (this.onLearn) {
      const fresh = [...keys].find((k) => !previous.has(k));
      if (fresh) this.onLearn(fresh);
      return;
    }
    this.evaluate();
  }

  remove(source: string): void {
    if (!this.pressed.delete(source)) return;
    this.evaluate();
  }

  private evaluate(): void {
    const buttons: ClickButtons = { plus: false, minus: false };
    for (const keys of this.pressed.values()) {
      for (const key of keys) {
        const direction = this.direction(key);
        if (direction === "up") buttons.plus = true;
        if (direction === "down") buttons.minus = true;
      }
    }
    for (const action of this.interpreter.process(buttons)) {
      switch (action.kind) {
        case "shift":
          this.onShift?.(action.direction);
          break;
        case "startRepeat":
          this.startRepeat(action.direction);
          break;
        case "stopRepeat":
          this.stopRepeat();
          break;
        case "bothPressed":
          this.onBothButtons?.();
          break;
      }
    }
  }

  private stopRepeat(): void {
    if (this.repeatTimer) clearTimeout(this.repeatTimer);
    this.repeatTimer = null;
  }

  /** Holding a button repeats the shift after a short delay. */
  private startRepeat(direction: ShiftDirection): void {
    this.stopRepeat();
    const tick = () => {
      if (!this.interpreter.isHeld(direction)) {
        this.repeatTimer = null;
        return;
      }
      this.onShift?.(direction);
      this.repeatTimer = setTimeout(tick, 200);
    };
    this.repeatTimer = setTimeout(tick, 450);
  }
}

// MARK: - Device classification

export type DeviceRole = "trainer" | "click" | "clickLeft" | "heartRate" | "cadence";

export const deviceRoles: DeviceRole[] = ["trainer", "click", "clickLeft", "heartRate", "cadence"];

export const roleInfo: Record<DeviceRole, { title: string; shortLabel: string }> = {
  trainer: { title: "Trainer", shortLabel: "KICKR" },
  click: { title: "Zwift Click", shortLabel: "CLICK" },
  clickLeft: { title: "Click v2 links (−)", shortLabel: "CLICK −" },
  heartRate: { title: "Pulsgurt", shortLabel: "PULS" },
  cadence: { title: "Kadenz", shortLabel: "KADENZ" },
};

export const isClickRole = (role: DeviceRole) => role === "click" || role === "clickLeft";
/** Optional roles never block a ride and stay hidden until a device shows up. */
export const isOptionalExtra = (role: DeviceRole) => role === "clickLeft";

/** Device type byte in Zwift's manufacturer data (company 0x094A, then type, then short address). */
export const ZwiftDeviceType = {
  click: 0x09,
  clickV2Right: 0x0a,
  clickV2Left: 0x0b,
  pod(type: number | null | undefined): ClickPod | null {
    if (type === ZwiftDeviceType.clickV2Right) return "right";
    if (type === ZwiftDeviceType.clickV2Left) return "left";
    if (type === ZwiftDeviceType.click) return "v1";
    return null;
  },
};

/** Manufacturer data by company id (the payload after the id), as BlueZ reports it. */
export type ManufacturerData = Record<number, Bytes>;

export const DeviceClassifier = {
  /** Zwift device type from the advertisement, or null for other manufacturers. */
  zwiftDeviceType(data: ManufacturerData | null | undefined): number | null {
    const payload = data?.[BLEUUID.zwiftManufacturerId];
    if (!payload) return null;
    return payload.length >= 1 ? payload[0] : 0;
  },

  /** Readable trainer model for the device list, e.g. "KICKR CORE 2". */
  trainerModel(name: string): string | null {
    const upper = name.toUpperCase();
    if (upper.includes("KICKR CORE 2") || upper.includes("KICKRCORE2")) return "Kickr Core 2";
    if (upper.includes("KICKR CORE")) return "Kickr Core";
    if (upper.includes("KICKR")) return "Kickr";
    return null;
  },

  roles(name: string, services: string[], manufacturerData: ManufacturerData | null | undefined): DeviceRole[] {
    const upper = name.toUpperCase();
    const has = (uuid: string) => services.some((s) => s.toLowerCase() === uuid);
    if (has(BLEUUID.ftmsService) || upper.includes("KICKR")) return ["trainer"];
    const type = DeviceClassifier.zwiftDeviceType(manufacturerData);
    if (type != null) return type === ZwiftDeviceType.clickV2Left ? ["clickLeft"] : ["click"];
    if (upper.includes("ZWIFT CLICK") || upper.includes("ZWIFT SF2") || has(BLEUUID.zwiftAdvertised)) return ["click"];
    const roles: DeviceRole[] = [];
    if (has(BLEUUID.heartRateService)) roles.push("heartRate");
    if (has(BLEUUID.cscService)) roles.push("cadence");
    return roles;
  },
};

// MARK: - Live sensor values

/** Latest sensor values, with timestamps (ms) so stale values can be ignored. */
export class LiveSensors {
  trainerPower: number | null = null;
  trainerCadence: number | null = null;
  /** m/s, as reported by the trainer */
  trainerSpeedValue: number | null = null;
  trainerUpdated: number | null = null;
  heartRateValue: number | null = null;
  heartRateUpdated: number | null = null;
  pedalCadence: number | null = null;
  pedalUpdated: number | null = null;

  private fresh(at: number | null, now: number, maxAge = 3): boolean {
    return at != null && (now - at) / 1000 <= maxAge;
  }

  power(now: number): number | null {
    return this.fresh(this.trainerUpdated, now) ? this.trainerPower : null;
  }

  /** Pedal sensor first, trainer cadence as fallback. */
  cadence(now: number): number | null {
    if (this.fresh(this.pedalUpdated, now) && this.pedalCadence != null) return this.pedalCadence;
    return this.fresh(this.trainerUpdated, now) ? this.trainerCadence : null;
  }

  heartRate(now: number): number | null {
    return this.fresh(this.heartRateUpdated, now, 5) ? this.heartRateValue : null;
  }

  trainerSpeed(now: number): number | null {
    return this.fresh(this.trainerUpdated, now) ? this.trainerSpeedValue : null;
  }
}
