// Ride recording, summary, FIT encoder/decoder and the stored history entry.
import { Fmt, PowerZones, rnd } from "./basics";

export interface RideSample {
  /** ms since the Unix epoch */
  timestamp: number;
  elapsed: number;
  power: number;
  cadence: number | null;
  heartRate: number | null;
  /** m/s */
  speed: number;
  /** metres */
  distance: number;
  /** metres above sea level */
  altitude: number;
  gradePercent: number;
}

export interface RideLap {
  startTime: number;
  endTime: number;
  startElapsed: number;
  endElapsed: number;
  /** [start, end) sample indices */
  from: number;
  to: number;
}

export interface RideSummary {
  startTime: number;
  endTime: number;
  movingTime: number;
  elapsedTime: number;
  distance: number;
  avgPower: number;
  maxPower: number;
  normalizedPower: number;
  avgCadence: number | null;
  maxCadence: number | null;
  avgHeartRate: number | null;
  maxHeartRate: number | null;
  avgSpeed: number;
  maxSpeed: number;
  ascent: number;
  kilojoules: number;
}

const sum = (a: number[]) => a.reduce((s, x) => s + x, 0);
const avg = (a: number[]) => (a.length === 0 ? null : rnd(sum(a) / a.length));
const maxOf = (a: number[]) => (a.length === 0 ? null : Math.max(...a));

/** Normalized power: 30 s rolling average, raised to the 4th power, averaged, 4th root. */
export function normalizedPower(powers: number[]): number {
  if (powers.length === 0) return 0;
  if (powers.length < 30) return rnd(sum(powers) / powers.length);
  let window = sum(powers.slice(0, 30));
  let sum4 = 0;
  let count = 0;
  for (let i = 29; i < powers.length; i++) {
    if (i > 29) window += powers[i] - powers[i - 30];
    sum4 += Math.pow(window / 30, 4);
    count += 1;
  }
  return rnd(Math.pow(sum4 / count, 0.25));
}

export function computeSummary(samples: RideSample[], startTime: number, endTime: number): RideSummary {
  const powers = samples.map((s) => s.power);
  const cadences = samples.map((s) => s.cadence).filter((c): c is number => c != null && c > 0);
  const hrs = samples.map((s) => s.heartRate).filter((h): h is number => h != null && h > 0);
  const first = samples[0];
  const last = samples[samples.length - 1];
  const moving = (last?.elapsed ?? 0) - (first?.elapsed ?? 0) + (samples.length === 0 ? 0 : 1);
  const distance = Math.max(0, (last?.distance ?? 0) - (first ? first.distance - first.speed : 0));
  let ascent = 0;
  let previous: number | null = null;
  for (const s of samples) {
    if (previous != null && s.altitude > previous) ascent += s.altitude - previous;
    previous = s.altitude;
  }
  return {
    startTime,
    endTime,
    movingTime: moving,
    elapsedTime: (endTime - startTime) / 1000,
    distance,
    avgPower: avg(powers) ?? 0,
    maxPower: maxOf(powers) ?? 0,
    normalizedPower: normalizedPower(powers),
    avgCadence: avg(cadences),
    maxCadence: maxOf(cadences),
    avgHeartRate: avg(hrs),
    maxHeartRate: maxOf(hrs),
    avgSpeed: moving > 0 ? distance / moving : 0,
    maxSpeed: maxOf(samples.map((s) => s.speed)) ?? 0,
    ascent,
    kilojoules: sum(powers) / 1000,
  };
}

/** Collects 1 Hz samples and laps of a ride. */
export class RideRecorder {
  samples: RideSample[] = [];
  laps: RideLap[] = [];
  private lapStart: { time: number; elapsed: number; index: number } | null = null;

  add(sample: RideSample): void {
    if (!this.lapStart) this.lapStart = { time: sample.timestamp, elapsed: sample.elapsed, index: this.samples.length };
    this.samples.push(sample);
  }

  /** Closes the current lap and starts a new one. */
  markLap(time: number, elapsed: number): void {
    const start = this.lapStart;
    if (!start || this.samples.length <= start.index) return;
    this.laps.push({ startTime: start.time, endTime: time, startElapsed: start.elapsed, endElapsed: elapsed, from: start.index, to: this.samples.length });
    this.lapStart = { time, elapsed, index: this.samples.length };
  }

  finish(time: number, elapsed: number): void {
    this.markLap(time, elapsed);
    this.lapStart = null;
  }
}

// MARK: - FIT encoder

type BaseType = "enum" | "uint8" | "sint16" | "uint16" | "uint32" | "uint32z";

const baseTypes: Record<BaseType, { code: number; size: number; invalid: number }> = {
  enum: { code: 0x00, size: 1, invalid: 0xff },
  uint8: { code: 0x02, size: 1, invalid: 0xff },
  sint16: { code: 0x83, size: 2, invalid: 0x7fff },
  uint16: { code: 0x84, size: 2, invalid: 0xffff },
  uint32: { code: 0x86, size: 4, invalid: 0xffffffff },
  uint32z: { code: 0x8c, size: 4, invalid: 0 },
};

type Field = [number, BaseType];

/** Seconds between the Unix epoch and the FIT epoch (1989-12-31 00:00 UTC). */
export const fitEpochOffset = 631_065_600;

const crcTable = [0x0000, 0xcc01, 0xd801, 0x1400, 0xf001, 0x3c00, 0x2800, 0xe401, 0xa001, 0x6c00, 0x7800, 0xb401, 0x5000, 0x9c01, 0x8801, 0x4400];

export function fitCrc(bytes: ArrayLike<number>, initial = 0): number {
  let crc = initial;
  for (let n = 0; n < bytes.length; n++) {
    const byte = bytes[n];
    let tmp = crcTable[crc & 0xf];
    crc = (crc >> 4) & 0x0fff;
    crc = crc ^ tmp ^ crcTable[byte & 0xf];
    tmp = crcTable[crc & 0xf];
    crc = (crc >> 4) & 0x0fff;
    crc = crc ^ tmp ^ crcTable[(byte >> 4) & 0xf];
  }
  return crc;
}

/** Minimal writer for the Garmin FIT file format (activity files). */
export class FITEncoder {
  records: number[] = [];
  private definitions = new Map<number, Field[]>();

  define(local: number, global: number, fields: Field[]): void {
    this.records.push(0x40 | local, 0, 0, global & 0xff, global >> 8, fields.length);
    for (const [number, type] of fields) this.records.push(number, baseTypes[type].size, baseTypes[type].code);
    this.definitions.set(local, fields);
  }

  /** Writes a data message. `null` values are written as the FIT invalid value. */
  write(local: number, values: (number | null)[]): void {
    const fields = this.definitions.get(local);
    if (!fields) throw new Error(`message ${local} not defined`);
    if (values.length !== fields.length) throw new Error("field count mismatch");
    this.records.push(local);
    fields.forEach(([, type], i) => {
      const t = baseTypes[type];
      const range = 2 ** (8 * t.size);
      const value = values[i];
      let raw = value == null || !Number.isFinite(value) ? t.invalid : Math.trunc(value) % range;
      if (raw < 0) raw += range;
      for (let b = 0; b < t.size; b++) this.records.push(Math.floor(raw / 2 ** (8 * b)) & 0xff);
    });
  }

  /** Complete file: 14-byte header, records, file CRC. */
  data(): Uint8Array {
    const header = [14, 0x20];
    const profile = 2160;
    header.push(profile & 0xff, profile >> 8);
    const size = this.records.length;
    for (let i = 0; i < 4; i++) header.push(Math.floor(size / 2 ** (8 * i)) & 0xff);
    header.push(...[".", "F", "I", "T"].map((c) => c.charCodeAt(0)));
    const headerCRC = fitCrc(header);
    header.push(headerCRC & 0xff, headerCRC >> 8);
    const file = header.concat(this.records);
    const fileCRC = fitCrc(file);
    file.push(fileCRC & 0xff, fileCRC >> 8);
    return Uint8Array.from(file);
  }

  static timestamp(ms: number): number {
    return Math.trunc(Math.max(0, ms / 1000 - fitEpochOffset));
  }
}

const clampInt = (v: number, lo: number, hi: number) => Math.min(hi, Math.max(lo, v));

/** Builds a FIT activity file from a recorded ride. */
export function buildActivityFIT(samples: RideSample[], laps: RideLap[], summary: RideSummary): Uint8Array {
  const sportCycling = 2;
  const subSportVirtual = 58;
  const fit = new FITEncoder();
  const ts = FITEncoder.timestamp;
  const start = ts(summary.startTime);
  const end = ts(summary.endTime);

  // file_id: type, manufacturer, product, serial number, time created
  fit.define(0, 0, [[0, "enum"], [1, "uint16"], [2, "uint16"], [3, "uint32z"], [4, "uint32"]]);
  fit.write(0, [4, 255, 1, 20_261_112, start]);

  // event: timestamp, event, event type
  fit.define(1, 21, [[253, "uint32"], [0, "enum"], [1, "enum"]]);
  fit.write(1, [start, 0, 0]); // timer start

  // record: timestamp, altitude (scale 5, offset 500), heart rate, cadence, distance (cm), speed (mm/s), power, grade (scale 100)
  fit.define(2, 20, [[253, "uint32"], [2, "uint16"], [3, "uint8"], [4, "uint8"], [5, "uint32"], [6, "uint16"], [7, "uint16"], [9, "sint16"]]);
  for (const s of samples) {
    fit.write(2, [
      ts(s.timestamp),
      rnd((s.altitude + 500) * 5),
      s.heartRate == null ? null : clampInt(s.heartRate, 0, 254),
      s.cadence == null ? null : clampInt(s.cadence, 0, 254),
      rnd(s.distance * 100),
      rnd(s.speed * 1000),
      clampInt(s.power, 0, 65_534),
      rnd(s.gradePercent * 100),
    ]);
  }
  fit.write(1, [end, 0, 4]); // timer stop all

  // lap
  fit.define(3, 19, [
    [254, "uint16"], [253, "uint32"], [0, "enum"], [1, "enum"], [2, "uint32"], [7, "uint32"], [8, "uint32"], [9, "uint32"],
    [13, "uint16"], [14, "uint16"], [15, "uint8"], [16, "uint8"], [17, "uint8"], [18, "uint8"], [19, "uint16"], [20, "uint16"],
    [21, "uint16"], [25, "enum"], [39, "enum"],
  ]);
  const lapList: RideLap[] =
    laps.length === 0
      ? [{ startTime: summary.startTime, endTime: summary.endTime, startElapsed: 0, endElapsed: summary.movingTime, from: 0, to: samples.length }]
      : laps;
  lapList.forEach((l, i) => {
    const slice = samples.slice(clampInt(l.from, 0, samples.length), clampInt(l.to, 0, samples.length));
    const ls = computeSummary(slice, l.startTime, l.endTime);
    fit.write(3, [
      i, ts(l.endTime), 9, 1, ts(l.startTime),
      Math.trunc(ls.elapsedTime * 1000), Math.trunc(ls.movingTime * 1000), rnd(ls.distance * 100),
      rnd(ls.avgSpeed * 1000), rnd(ls.maxSpeed * 1000),
      ls.avgHeartRate, ls.maxHeartRate, ls.avgCadence, ls.maxCadence, ls.avgPower, ls.maxPower,
      rnd(ls.ascent), sportCycling, subSportVirtual,
    ]);
  });

  // session
  fit.define(4, 18, [
    [254, "uint16"], [253, "uint32"], [0, "enum"], [1, "enum"], [2, "uint32"], [5, "enum"], [6, "enum"], [7, "uint32"],
    [8, "uint32"], [9, "uint32"], [11, "uint16"], [14, "uint16"], [15, "uint16"], [16, "uint8"], [17, "uint8"], [18, "uint8"],
    [19, "uint8"], [20, "uint16"], [21, "uint16"], [22, "uint16"], [25, "uint16"], [26, "uint16"], [28, "enum"], [34, "uint16"],
  ]);
  fit.write(4, [
    0, end, 8, 1, start, sportCycling, subSportVirtual,
    Math.trunc(summary.elapsedTime * 1000), Math.trunc(summary.movingTime * 1000), rnd(summary.distance * 100),
    rnd(summary.kilojoules), rnd(summary.avgSpeed * 1000), rnd(summary.maxSpeed * 1000),
    summary.avgHeartRate, summary.maxHeartRate, summary.avgCadence, summary.maxCadence, summary.avgPower, summary.maxPower,
    rnd(summary.ascent), 0, lapList.length, 0, summary.normalizedPower,
  ]);

  // activity: timestamp, total timer time, sessions, type, event, event type, local timestamp
  fit.define(5, 34, [[253, "uint32"], [0, "uint32"], [1, "uint16"], [2, "enum"], [3, "enum"], [4, "enum"], [5, "uint32"]]);
  const offset = -new Date(summary.endTime).getTimezoneOffset() * 60;
  fit.write(5, [end, Math.trunc(summary.movingTime * 1000), 1, 0, 26, 1, end + offset]);

  return fit.data();
}

// MARK: - FIT decoder

export class FITError extends Error {}

export interface FITMessage {
  global: number;
  /** Raw field values by field number; invalid values are left out. */
  fields: Map<number, number>;
}

interface Definition {
  global: number;
  bigEndian: boolean;
  fields: { number: number; size: number; base: number }[];
  developerBytes: number;
}

const baseSizes: Record<number, number> = { 0x00: 1, 0x01: 1, 0x02: 1, 0x0a: 1, 0x0d: 1, 0x83: 2, 0x84: 2, 0x8b: 2, 0x85: 4, 0x86: 4, 0x8c: 4 };

/** One integer value of a field, or null for invalid values, strings, floats and arrays. */
function decodeField(bytes: Uint8Array, base: number, bigEndian: boolean): number | null {
  const size = baseSizes[base];
  if (size == null || bytes.length !== size) return null;
  let raw = 0;
  for (let i = 0; i < size; i++) raw = raw * 256 + bytes[bigEndian ? i : size - 1 - i];
  switch (base) {
    case 0x00:
    case 0x02:
    case 0x0d:
      return raw === 0xff ? null : raw;
    case 0x0a:
    case 0x8b:
    case 0x8c:
      return raw === 0 ? null : raw;
    case 0x01:
      return raw === 0x7f ? null : raw > 0x7f ? raw - 0x100 : raw;
    case 0x84:
      return raw === 0xffff ? null : raw;
    case 0x83:
      return raw === 0x7fff ? null : raw > 0x7fff ? raw - 0x10000 : raw;
    case 0x86:
      return raw === 0xffffffff ? null : raw;
    case 0x85:
      return raw === 0x7fffffff ? null : raw > 0x7fffffff ? raw - 0x100000000 : raw;
    default:
      return null;
  }
}

/** Reads FIT activity files, so rides saved by hand (or from other apps) can be shown and uploaded. */
export function fitMessages(b: Uint8Array): FITMessage[] {
  if (b.length < 12 || String.fromCharCode(b[8], b[9], b[10], b[11]) !== ".FIT") throw new FITError("Das ist keine FIT-Datei.");
  const truncated = () => new FITError("Die FIT-Datei ist unvollständig.");
  const headerSize = b[0];
  const dataSize = b[4] + b[5] * 256 + b[6] * 65536 + b[7] * 16777216;
  const end = Math.min(b.length, headerSize + dataSize);
  let i = headerSize;
  const definitions = new Map<number, Definition>();
  let lastTimestamp = 0;
  const messages: FITMessage[] = [];

  const readFields = (def: Definition): FITMessage => {
    const values = new Map<number, number>();
    for (const field of def.fields) {
      if (i + field.size > end) throw truncated();
      const value = decodeField(b.subarray(i, i + field.size), field.base, def.bigEndian);
      if (value != null) values.set(field.number, value);
      i += field.size;
    }
    if (i + def.developerBytes > end) throw truncated();
    i += def.developerBytes;
    return { global: def.global, fields: values };
  };

  while (i < end) {
    const header = b[i];
    i += 1;
    if (header & 0x80) {
      // Compressed timestamp header: the low 5 bits are a time offset.
      const def = definitions.get((header >> 5) & 0x03);
      if (!def) throw truncated();
      const message = readFields(def);
      const offset = header & 0x1f;
      let timestamp = lastTimestamp - (lastTimestamp % 32) + offset;
      if (timestamp < lastTimestamp) timestamp += 0x20;
      lastTimestamp = timestamp;
      message.fields.set(253, timestamp);
      messages.push(message);
      continue;
    }
    const local = header & 0x0f;
    if (header & 0x40) {
      if (i + 5 > end) throw truncated();
      const bigEndian = b[i + 1] === 1;
      const global = bigEndian ? (b[i + 2] << 8) | b[i + 3] : b[i + 2] | (b[i + 3] << 8);
      const count = b[i + 4];
      i += 5;
      const fields: Definition["fields"] = [];
      for (let k = 0; k < count; k++) {
        if (i + 3 > end) throw truncated();
        fields.push({ number: b[i], size: b[i + 1], base: b[i + 2] });
        i += 3;
      }
      let developerBytes = 0;
      if (header & 0x20) {
        if (i >= end) throw truncated();
        const n = b[i];
        i += 1;
        for (let k = 0; k < n; k++) {
          if (i + 3 > end) throw truncated();
          developerBytes += b[i + 1];
          i += 3;
        }
      }
      definitions.set(local, { global, bigEndian, fields, developerBytes });
    } else {
      const def = definitions.get(local);
      if (!def) throw truncated();
      const message = readFields(def);
      const ts = message.fields.get(253);
      if (ts != null) lastTimestamp = ts;
      messages.push(message);
    }
  }
  return messages;
}

/** Ride samples from the record messages, plus the moving time from the session if present. */
export function rideFromFIT(data: Uint8Array): { samples: RideSample[]; movingTime: number | null } {
  const all = fitMessages(data);
  const samples: RideSample[] = [];
  let first: number | null = null;
  for (const m of all) {
    if (m.global !== 20) continue;
    const ts = m.fields.get(253);
    if (ts == null) continue;
    if (first == null) first = ts;
    const last = samples[samples.length - 1];
    const f = (n: number) => m.fields.get(n);
    const rawAltitude = f(78) ?? f(2);
    const rawSpeed = f(73) ?? f(6);
    const rawDistance = f(5);
    const rawGrade = f(9);
    samples.push({
      timestamp: (ts + fitEpochOffset) * 1000,
      elapsed: ts - first,
      power: f(7) ?? 0,
      cadence: f(4) ?? null,
      heartRate: f(3) ?? null,
      speed: rawSpeed != null ? rawSpeed / 1000 : 0,
      distance: rawDistance != null ? rawDistance / 100 : last?.distance ?? 0,
      altitude: rawAltitude != null ? rawAltitude / 5 - 500 : last?.altitude ?? 0,
      gradePercent: rawGrade != null ? rawGrade / 100 : 0,
    });
  }
  if (samples.length === 0) throw new FITError("Die FIT-Datei enthält keine Fahrtdaten.");
  const session = all.find((m) => m.global === 18);
  const moving = session?.fields.get(8);
  return { samples, movingTime: moving != null ? moving / 1000 : null };
}

// MARK: - Stored history entry (same JSON layout as the macOS app)

export interface StoredSummary {
  movingTime: number;
  elapsedTime: number;
  distance: number;
  avgPower: number;
  maxPower: number;
  normalizedPower: number;
  avgCadence?: number | null;
  avgHeartRate?: number | null;
  maxHeartRate?: number | null;
  avgSpeed: number;
  maxSpeed: number;
  ascent: number;
  kilojoules: number;
}

/** Downsampled curves of a ride for the charts (at most a few hundred points). */
export interface StoredSeries {
  bucketSeconds: number;
  power: number[];
  /** 0 = no heart rate in this bucket. */
  heartRate: number[];
  cadence: number[];
  altitude: number[];
  distance: number[];
}

export function makeSeries(samples: RideSample[], maxPoints = 360): StoredSeries {
  const n = samples.length;
  const series: StoredSeries = { bucketSeconds: 1, power: [], heartRate: [], cadence: [], altitude: [], distance: [] };
  if (n === 0) return series;
  const bucket = Math.max(1, Math.ceil(n / maxPoints));
  series.bucketSeconds = bucket;
  for (let start = 0; start < n; start += bucket) {
    const slice = samples.slice(start, Math.min(n, start + bucket));
    series.power.push(rnd(sum(slice.map((s) => s.power)) / slice.length));
    series.heartRate.push(avg(slice.map((s) => s.heartRate).filter((h): h is number => h != null && h > 0)) ?? 0);
    series.cadence.push(avg(slice.map((s) => s.cadence).filter((c): c is number => c != null && c > 0)) ?? 0);
    series.altitude.push(slice[slice.length - 1].altitude);
    series.distance.push(slice[slice.length - 1].distance);
  }
  return series;
}

export interface RideEntry {
  /** FIT file name, also the id. */
  id: string;
  name: string;
  description?: string | null;
  pairedEventId?: number | null;
  /** ISO date */
  date: string;
  distance: number;
  movingTime: number;
  uploadedActivityId?: string | null;
  lastError?: string | null;
  /** Course or workout, shown under the name. */
  subtitle?: string | null;
  summary?: StoredSummary | null;
  series?: StoredSeries | null;
  /** Seconds in Z1…Z6. */
  zoneSeconds?: number[] | null;
  ftp?: number | null;
  /** FTP found by an FTP test in this ride. */
  ftpTestResult?: number | null;
}

export function makeEntry(p: {
  id: string;
  name: string;
  subtitle: string | null;
  description: string | null;
  pairedEventId: number | null;
  samples: RideSample[];
  summary: RideSummary;
  ftp: number;
  zones: PowerZones;
}): RideEntry {
  const zoneSeconds = [0, 0, 0, 0, 0, 0];
  for (const s of p.samples) if (s.power > 0) zoneSeconds[p.zones.index(s.power, p.ftp)] += 1;
  const s = p.summary;
  return {
    id: p.id,
    name: p.name,
    description: p.description,
    pairedEventId: p.pairedEventId,
    date: new Date(s.startTime).toISOString().replace(/\.\d{3}Z$/, "Z"),
    distance: s.distance,
    movingTime: s.movingTime,
    subtitle: p.subtitle,
    summary: {
      movingTime: s.movingTime,
      elapsedTime: s.elapsedTime,
      distance: s.distance,
      avgPower: s.avgPower,
      maxPower: s.maxPower,
      normalizedPower: s.normalizedPower,
      avgCadence: s.avgCadence,
      avgHeartRate: s.avgHeartRate,
      maxHeartRate: s.maxHeartRate,
      avgSpeed: s.avgSpeed,
      maxSpeed: s.maxSpeed,
      ascent: s.ascent,
      kilojoules: s.kilojoules,
    },
    series: makeSeries(p.samples),
    zoneSeconds,
    ftp: p.ftp,
  };
}

/** Creates the history entry for a FIT file: figures and curves are read from the file. */
export function entryFromFIT(data: Uint8Array, id: string, fallbackName: string, ftp: number, zones: PowerZones): RideEntry {
  const ride = rideFromFIT(data);
  const first = ride.samples[0].timestamp;
  const last = ride.samples[ride.samples.length - 1].timestamp;
  const summary = computeSummary(ride.samples, first, last);
  if (ride.movingTime != null && ride.movingTime > 0) summary.movingTime = ride.movingTime;
  const name = summary.distance > 0 ? `Bike App – ${Fmt.km(summary.distance)} km` : fallbackName;
  return makeEntry({ id, name, subtitle: "Importiert", description: "Gefahren mit Bike App", pairedEventId: null, samples: ride.samples, summary, ftp, zones });
}
