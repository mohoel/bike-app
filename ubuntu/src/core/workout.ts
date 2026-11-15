import { PowerZones, rnd } from "./basics";

export type StepKind = "steady" | "ramp" | "free";

export interface WorkoutStep {
  duration: number;
  kind: StepKind;
  /** Fraction of FTP at the start of the step (null for free ride). */
  startFraction: number | null;
  /** Fraction of FTP at the end of the step (equals start for steady steps). */
  endFraction: number | null;
  label: string | null;
}

export const Step = {
  steady(duration: number, fraction: number, label: string | null = null): WorkoutStep {
    return { duration, kind: "steady", startFraction: fraction, endFraction: fraction, label };
  },
  ramp(duration: number, from: number, to: number, label: string | null = null): WorkoutStep {
    return { duration, kind: "ramp", startFraction: from, endFraction: to, label };
  },
  free(duration: number, label: string | null = null): WorkoutStep {
    return { duration, kind: "free", startFraction: null, endFraction: null, label };
  },
  /** Target as fraction of FTP at `t` seconds into the step. */
  fraction(step: WorkoutStep, t: number): number | null {
    if (step.startFraction == null) return null;
    const start = step.startFraction;
    const end = step.endFraction ?? start;
    if (step.kind !== "ramp" || !(step.duration > 0)) return start;
    const p = Math.min(1, Math.max(0, t / step.duration));
    return start + (end - start) * p;
  },
  hasTarget(step: WorkoutStep): boolean {
    return step.startFraction != null;
  },
  equal(a: WorkoutStep, b: WorkoutStep): boolean {
    return (
      a.duration === b.duration &&
      a.kind === b.kind &&
      a.startFraction === b.startFraction &&
      a.endFraction === b.endFraction &&
      (a.label ?? null) === (b.label ?? null)
    );
  },
};

export interface Workout {
  id: string;
  name: string;
  /** ISO date of a planned workout. */
  date: string | null;
  /** intervals.icu calendar event, used to pair the uploaded ride. */
  eventId: number | null;
  description: string | null;
  steps: WorkoutStep[];
}

export function workoutDuration(w: { steps: WorkoutStep[] }): number {
  return w.steps.reduce((sum, s) => sum + s.duration, 0);
}

export interface WorkoutPosition {
  index: number;
  step: WorkoutStep;
  stepStart: number;
  timeInStep: number;
  remainingInStep: number;
}

/** Answers "where am I in the workout" for a given moving time. */
export class WorkoutPlayer {
  private readonly starts: number[] = [];
  readonly duration: number;

  constructor(readonly workout: Workout) {
    let t = 0;
    for (const step of workout.steps) {
      this.starts.push(t);
      t += step.duration;
    }
    this.duration = t;
  }

  position(time: number): WorkoutPosition | null {
    const steps = this.workout.steps;
    if (steps.length === 0 || !(time < this.duration)) return null;
    const t = Math.max(0, time);
    let index = steps.length - 1;
    for (let i = 0; i < steps.length; i++) {
      if (this.starts[i] + steps[i].duration > t) {
        index = i;
        break;
      }
    }
    const step = steps[index];
    const inStep = t - this.starts[index];
    return { index, step, stepStart: this.starts[index], timeInStep: inStep, remainingInStep: step.duration - inStep };
  }

  targetFraction(time: number): number | null {
    const p = this.position(time);
    return p ? Step.fraction(p.step, p.timeInStep) : null;
  }

  nextStep(index: number): WorkoutStep | null {
    return this.workout.steps[index + 1] ?? null;
  }

  /** Number of the current interval among steps with the same target, e.g. "2 / 3". */
  repetition(index: number): { current: number; total: number } | null {
    const step = this.workout.steps[index];
    if (!step || !Step.hasTarget(step)) return null;
    const same: number[] = [];
    this.workout.steps.forEach((s, i) => {
      if (s.startFraction === step.startFraction && s.endFraction === step.endFraction && s.duration === step.duration) same.push(i);
    });
    if (same.length <= 1) return null;
    return { current: Math.max(0, same.indexOf(index)) + 1, total: same.length };
  }
}

// MARK: - FTP test

export type FTPTestKind = "ramp" | "twenty";

export const ftpTestKinds: { id: FTPTestKind; title: string; shortTitle: string; detail: string; factor: number }[] = [
  {
    id: "ramp",
    title: "Rampentest",
    shortTitle: "Rampe",
    detail:
      "Nach 5 Minuten Aufwärmen steigt die Leistung jede Minute an, bis du nicht mehr kannst. Der Kickr hält die Watt per ERG. FTP = 75 % deiner besten Minute. Dauer etwa 20–30 Minuten.",
    factor: 0.75,
  },
  {
    id: "twenty",
    title: "20-Minuten-Test",
    shortTitle: "20 Minuten",
    detail:
      "Geführtes Aufwärmen mit kurzen Antritten, dann 20 Minuten so hart und gleichmäßig wie möglich. Dabei schaltest du selbst. FTP = 95 % deiner 20-Minuten-Leistung. Dauer etwa 56 Minuten.",
    factor: 0.95,
  },
];

export function ftpTestKind(id: FTPTestKind) {
  return ftpTestKinds.find((k) => k.id === id)!;
}

/** The steps of a test and the part of it that is evaluated. */
export interface FTPTestPlan {
  kind: FTPTestKind;
  /** FTP the targets are based on (the current one). */
  baseFTP: number;
  /** True when the base FTP is a real value (from intervals.icu), not just the default. */
  baseIsKnown: boolean;
  workout: Workout;
  effortStart: number;
  effortEnd: number;
  /** Ramp: watts added per minute. */
  rampStep: number;
}

export const testCooldown: WorkoutStep = Step.steady(300, 0.4, "Ausfahren");

const sumDuration = (steps: WorkoutStep[]) => steps.reduce((s, x) => s + x.duration, 0);

export function makeTestPlan(kind: FTPTestKind, ftp: number, baseIsKnown: boolean): FTPTestPlan {
  const f = Math.max(80, ftp);
  if (kind === "ramp") {
    const warmup = [Step.steady(180, 0.45, "Aufwärmen"), Step.steady(120, 0.55, "Aufwärmen")];
    const start = Math.max(50, rnd((0.5 * f) / 5) * 5);
    const step = Math.max(10, rnd((0.06 * f) / 5) * 5);
    const ramp: WorkoutStep[] = [];
    let watts = start;
    let n = 1;
    while (watts <= 2 * f) {
      ramp.push(Step.steady(60, watts / f, `Rampe · Stufe ${n}`));
      watts += step;
      n += 1;
    }
    const effortStart = sumDuration(warmup);
    const effortEnd = effortStart + sumDuration(ramp);
    const workout: Workout = {
      id: "ftp-test-ramp",
      name: "FTP-Test · Rampe",
      date: null,
      eventId: null,
      description: null,
      steps: [...warmup, ...ramp, testCooldown],
    };
    return { kind, baseFTP: ftp, baseIsKnown, workout, effortStart, effortEnd, rampStep: step };
  }
  const steps: WorkoutStep[] = [Step.steady(600, 0.55, "Aufwärmen")];
  for (let i = 0; i < 3; i++) {
    steps.push(Step.steady(60, 1.0, "Antritt"));
    steps.push(Step.steady(60, 0.55, "Locker"));
  }
  steps.push(Step.steady(300, 1.05, "Vorbelastung"));
  steps.push(Step.steady(300, 0.5, "Locker"));
  const effortStart = sumDuration(steps);
  steps.push(Step.free(1200, "20 Minuten Vollgas"));
  steps.push(Step.steady(600, 0.45, "Ausfahren"));
  const workout: Workout = { id: "ftp-test-20", name: "FTP-Test · 20 Minuten", date: null, eventId: null, description: null, steps };
  return { kind, baseFTP: ftp, baseIsKnown, workout, effortStart, effortEnd: effortStart + 1200, rampStep: 0 };
}

/** The workout cut at `time` and followed by the cooldown (used when the ramp ends early). */
export function truncatedTestWorkout(workout: Workout, time: number): Workout {
  const steps: WorkoutStep[] = [];
  let t = 0;
  for (const step of workout.steps) {
    if (t + step.duration <= time) {
      steps.push(step);
    } else {
      const done = time - t;
      if (done >= 1) steps.push({ ...step, duration: done });
      break;
    }
    t += step.duration;
  }
  return { ...workout, steps: [...steps, testCooldown] };
}

export interface FTPTestResult {
  kind: FTPTestKind;
  ftp: number;
  /** Best minute (ramp) or 20-minute average (twenty). */
  basis: number;
  effortSeconds: number;
  completed: boolean;
  plausible: boolean;
  reason: string | null;
}

export function testBasisText(r: FTPTestResult): string {
  return r.kind === "ramp" ? `Beste Minute ${r.basis} W × 75 %` : `20-Minuten-Schnitt ${r.basis} W × 95 %`;
}

const sum = (a: number[]) => a.reduce((s, x) => s + x, 0);

/** Follows the test effort second by second: best minute, average, end of the ramp. */
export class FTPTestTracker {
  effortPowers: number[] = [];
  bestMinute = 0;
  finished = false;
  result: FTPTestResult | null = null;
  private lowCadence = 0;
  private lowPower = 0;

  constructor(readonly plan: FTPTestPlan) {}

  isInEffort(time: number): boolean {
    return !this.finished && time >= this.plan.effortStart && time < this.plan.effortEnd;
  }

  /** Feeds one second. Returns true when the effort just ended. */
  add(time: number, power: number, cadence: number, target: number | null): boolean {
    if (this.finished || time < this.plan.effortStart) return false;
    if (time >= this.plan.effortEnd) {
      this.finish(true);
      return true;
    }
    this.effortPowers.push(Math.max(0, power));
    if (this.effortPowers.length >= 60) {
      this.bestMinute = Math.max(this.bestMinute, sum(this.effortPowers.slice(-60)) / 60);
    }
    if (this.plan.kind === "ramp") {
      this.lowCadence = cadence < 50 ? this.lowCadence + 1 : 0;
      if (target != null && target > 0 && power < 0.7 * target) this.lowPower += 1;
      else this.lowPower = 0;
      if (this.lowCadence >= 6 || this.lowPower >= 8) {
        this.finish(true);
        return true;
      }
    }
    return false;
  }

  /** The rider ends the effort (ramp: "I'm done"; 20 minutes: abort). */
  endManually(): void {
    if (this.finished) return;
    this.finish(this.plan.kind === "ramp");
  }

  /** Running FTP estimate during the effort. */
  get estimate(): number | null {
    const n = this.effortPowers.length;
    if (n === 0) return null;
    const factor = ftpTestKind(this.plan.kind).factor;
    if (this.plan.kind === "ramp") {
      const basis = n >= 60 ? this.bestMinute : sum(this.effortPowers) / n;
      return rnd(basis * factor);
    }
    return rnd((sum(this.effortPowers) / n) * factor);
  }

  get average(): number | null {
    const n = this.effortPowers.length;
    return n === 0 ? null : rnd(sum(this.effortPowers) / n);
  }

  private finish(completed: boolean): void {
    this.finished = true;
    const seconds = this.effortPowers.length;
    const kind = this.plan.kind;
    const basis = kind === "ramp" ? (seconds >= 60 ? this.bestMinute : 0) : seconds > 0 ? sum(this.effortPowers) / seconds : 0;
    const ftp = rnd(basis * ftpTestKind(kind).factor);
    let reason: string | null = null;
    if (kind === "ramp" && seconds < 240) {
      reason = "Die Rampe war kürzer als 4 Minuten.";
    } else if (kind === "twenty" && seconds < 1140) {
      reason = "Die 20 Minuten wurden nicht zu Ende gefahren.";
    } else if (ftp < 60 || ftp > 600) {
      reason = "Das Ergebnis liegt außerhalb von 60–600 W.";
    } else if (this.plan.baseIsKnown && (ftp < 0.6 * this.plan.baseFTP || ftp > 1.5 * this.plan.baseFTP)) {
      reason = `Das Ergebnis weicht stark von deiner bisherigen FTP (${this.plan.baseFTP} W) ab.`;
    }
    this.result = {
      kind,
      ftp,
      basis: rnd(basis),
      effortSeconds: seconds,
      completed: completed && reason == null,
      plausible: reason == null,
      reason,
    };
  }
}

// MARK: - Workouts built in the app

export type BlockKind = "steady" | "ramp" | "free" | "repeats";

export const blockKindTitles: Record<BlockKind, string> = { steady: "Konstant", ramp: "Rampe", free: "Frei", repeats: "Wiederholung" };

/** One block of a workout built in the app: a step or a repeated group of steps. */
export interface WorkoutBlock {
  id: string;
  kind: BlockKind;
  /** Seconds; unused for repeats. */
  duration: number;
  /** Percent of FTP at the start (and for steady steps). */
  startPercent: number;
  /** Percent of FTP at the end of a ramp. */
  endPercent: number;
  label: string;
  reps: number;
  /** Steps of a repeat group (one level, no nested repeats). */
  children: WorkoutBlock[];
}

export function newId(): string {
  return globalThis.crypto.randomUUID().toUpperCase();
}

export const Block = {
  steady(minutes: number, percent: number, label = ""): WorkoutBlock {
    return { id: newId(), kind: "steady", duration: minutes * 60, startPercent: percent, endPercent: percent, label, reps: 3, children: [] };
  },
  ramp(minutes: number, from: number, to: number, label = ""): WorkoutBlock {
    return { id: newId(), kind: "ramp", duration: minutes * 60, startPercent: from, endPercent: to, label, reps: 3, children: [] };
  },
  free(minutes: number, label = ""): WorkoutBlock {
    return { id: newId(), kind: "free", duration: minutes * 60, startPercent: 75, endPercent: 75, label, reps: 3, children: [] };
  },
  repeats(reps: number, children: WorkoutBlock[]): WorkoutBlock {
    return { id: newId(), kind: "repeats", duration: 300, startPercent: 75, endPercent: 75, label: "", reps, children };
  },
  /** Same block with fresh ids (for duplicating). */
  copy(b: WorkoutBlock): WorkoutBlock {
    return { ...b, id: newId(), children: b.children.map(Block.copy) };
  },
  totalDuration(b: WorkoutBlock): number {
    if (b.kind !== "repeats") return b.duration;
    return Math.max(1, b.reps) * b.children.reduce((s, c) => s + Block.totalDuration(c), 0);
  },
  steps(b: WorkoutBlock): WorkoutStep[] {
    const text = b.label.trim() === "" ? null : b.label;
    switch (b.kind) {
      case "steady":
        return [Step.steady(b.duration, b.startPercent / 100, text)];
      case "ramp":
        return [Step.ramp(b.duration, b.startPercent / 100, b.endPercent / 100, text)];
      case "free":
        return [Step.free(b.duration, text)];
      case "repeats": {
        const inner = b.children.flatMap(Block.steps);
        const out: WorkoutStep[] = [];
        for (let i = 0; i < Math.max(1, b.reps); i++) out.push(...inner);
        return out;
      }
    }
  },
};

/** A workout created in the app. */
export interface CustomWorkout {
  id: string;
  name: string;
  notes: string;
  blocks: WorkoutBlock[];
  /** ISO date */
  modified: string;
}

export const customIdPrefix = "custom-";

/** ISO 8601 without fractional seconds (the format the macOS app writes). */
export function isoDate(date: Date = new Date()): string {
  return date.toISOString().replace(/\.\d{3}Z$/, "Z");
}

export const Custom = {
  make(name: string, blocks: WorkoutBlock[], notes = ""): CustomWorkout {
    return { id: newId(), name, notes, blocks, modified: isoDate() };
  },
  steps(w: CustomWorkout): WorkoutStep[] {
    return w.blocks.flatMap(Block.steps).filter((s) => s.duration > 0);
  },
  duration(w: CustomWorkout): number {
    return workoutDuration({ steps: Custom.steps(w) });
  },
  workoutId(w: CustomWorkout): string {
    return customIdPrefix + w.id;
  },
  asWorkout(w: CustomWorkout): Workout {
    return { id: Custom.workoutId(w), name: w.name, date: null, eventId: null, description: w.notes === "" ? null : w.notes, steps: Custom.steps(w) };
  },
  isValid(w: CustomWorkout): boolean {
    return w.name.trim() !== "" && Custom.duration(w) > 0;
  },
  /** Training stress estimate (free steps count as 50 % FTP). */
  stressScore(w: CustomWorkout): number {
    let total = 0;
    for (const step of Custom.steps(w)) {
      const a = step.startFraction ?? 0.5;
      const b = step.endFraction ?? a;
      // Mean of the squared intensity over a linear ramp.
      total += (step.duration * (a * a + a * b + b * b)) / 3;
    }
    return rnd((total / 3600) * 100);
  },
  /** Mean intensity (fraction of FTP) weighted by time. */
  intensityFactor(w: CustomWorkout): number {
    const total = Custom.duration(w);
    if (!(total > 0)) return 0;
    return Math.sqrt(((Custom.stressScore(w) / 100) * 3600) / total);
  },
  /** Workout text in intervals.icu syntax, e.g. "3x\n- 10m 90%\n- 5m 55%". */
  intervalsText(w: CustomWorkout): string {
    const time = (seconds: number) => {
      const s = rnd(seconds);
      if (s % 60 === 0) return `${s / 60}m`;
      if (s < 60) return `${s}s`;
      return `${Math.floor(s / 60)}m${s % 60}s`;
    };
    const line = (b: WorkoutBlock) => {
      const label = b.label.trim();
      const prefix = label === "" ? "- " : `- ${label} `;
      switch (b.kind) {
        case "steady":
          return `${prefix}${time(b.duration)} ${b.startPercent}%`;
        case "ramp":
          return `${prefix}${time(b.duration)} ramp ${b.startPercent}-${b.endPercent}%`;
        case "free":
          return `${prefix}${time(b.duration)} freeride`;
        default:
          return "";
      }
    };
    const parts: string[] = [];
    for (const block of w.blocks) {
      if (block.kind === "repeats") parts.push([`${Math.max(1, block.reps)}x`, ...block.children.map(line)].join("\n"));
      else parts.push(line(block));
    }
    // intervals.icu needs blank lines around repeat groups.
    return parts.join("\n\n");
  },
  /** Editable copy of an imported workout. Runs of identical step pairs become repeat groups. */
  from(workout: Workout): CustomWorkout {
    const percent = (f: number | null) => rnd((f ?? 0.5) * 100);
    const block = (step: WorkoutStep): WorkoutBlock => {
      const label = step.label ?? "";
      if (step.kind === "free") return Block.free(step.duration / 60, label);
      if (step.kind === "ramp") return Block.ramp(step.duration / 60, percent(step.startFraction), percent(step.endFraction), label);
      return Block.steady(step.duration / 60, percent(step.startFraction), label);
    };
    const steps = workout.steps;
    const blocks: WorkoutBlock[] = [];
    let i = 0;
    while (i < steps.length) {
      // Look for a pair (work, rest) that repeats at least twice.
      if (i + 3 < steps.length && Step.equal(steps[i], steps[i + 2]) && Step.equal(steps[i + 1], steps[i + 3])) {
        let reps = 2;
        while (i + reps * 2 + 1 < steps.length && Step.equal(steps[i + reps * 2], steps[i]) && Step.equal(steps[i + reps * 2 + 1], steps[i + 1])) {
          reps += 1;
        }
        blocks.push(Block.repeats(reps, [block(steps[i]), block(steps[i + 1])]));
        i += reps * 2;
      } else {
        blocks.push(block(steps[i]));
        i += 1;
      }
    }
    return Custom.make(workout.name, blocks, workout.description ?? "");
  },
  /** Starting points for new workouts. */
  templates(): CustomWorkout[] {
    return [
      Custom.make("Leeres Workout", [Block.ramp(10, 45, 70, "Aufwärmen"), Block.ramp(5, 65, 45, "Ausfahren")]),
      Custom.make("Sweet Spot 3 × 10", [
        Block.ramp(10, 45, 70, "Aufwärmen"),
        Block.repeats(3, [Block.steady(10, 90, "Sweet Spot"), Block.steady(5, 55, "Erholung")]),
        Block.ramp(10, 65, 45, "Ausfahren"),
      ]),
      Custom.make("VO2max 5 × 3", [
        Block.ramp(12, 45, 75, "Aufwärmen"),
        Block.repeats(5, [Block.steady(3, 115, "VO2max"), Block.steady(3, 50, "Erholung")]),
        Block.ramp(8, 60, 45, "Ausfahren"),
      ]),
      Custom.make("Grundlage 60", [Block.ramp(8, 45, 65, "Aufwärmen"), Block.steady(45, 68, "Grundlage"), Block.ramp(7, 60, 45, "Ausfahren")]),
      Custom.make("Schwelle 2 × 20", [
        Block.ramp(12, 45, 75, "Aufwärmen"),
        Block.repeats(2, [Block.steady(20, 97, "Schwelle"), Block.steady(8, 55, "Erholung")]),
        Block.ramp(8, 60, 45, "Ausfahren"),
      ]),
    ];
  },
};

/** "4:30" → 270, "10" → 600 (minutes), "1:02:00" → 3720. */
export function parseDuration(text: string): number | null {
  const parts = text.trim().split(":");
  if (parts.length === 0 || parts.some((p) => !/^\d+$/.test(p))) return null;
  const v = parts.map(Number);
  let total: number;
  if (v.length === 1) total = v[0] * 60;
  else if (v.length === 2) total = v[0] * 60 + v[1];
  else if (v.length === 3) total = v[0] * 3600 + v[1] * 60 + v[2];
  else return null;
  return total > 0 ? total : null;
}

export function formatDuration(seconds: number): string {
  const s = rnd(seconds);
  const p = (n: number) => String(n).padStart(2, "0");
  if (s >= 3600) return `${Math.floor(s / 3600)}:${p(Math.floor((s % 3600) / 60))}:${p(s % 60)}`;
  return `${Math.floor(s / 60)}:${p(s % 60)}`;
}

// MARK: - intervals.icu parser

/** Midpoints of the power zones in fraction of FTP, used for zone-based targets. */
const zoneMidpoints = [0.5, 0.65, 0.83, 0.98, 1.13, 1.35, 1.6];

export const rideTypes = new Set(["Ride", "VirtualRide", "GravelRide", "MountainBikeRide", "EBikeRide", "TrackRide"]);

type Json = Record<string, any>;

function num(value: unknown): number | null {
  if (typeof value === "number" && Number.isFinite(value)) return value;
  if (typeof value === "string" && value.trim() !== "" && Number.isFinite(Number(value))) return Number(value);
  return null;
}

export const IntervalsParser = {
  parseEvents(json: unknown, fallbackFTP: number): Workout[] {
    if (!Array.isArray(json)) return [];
    return json.map((e) => IntervalsParser.parseEvent(e, fallbackFTP)).filter((w): w is Workout => w != null);
  },

  parseLibrary(json: unknown, fallbackFTP: number): Workout[] {
    if (!Array.isArray(json)) return [];
    return json
      .map((item) => {
        const { category: _ignored, ...copy } = item ?? {};
        return IntervalsParser.parseEvent(copy, fallbackFTP);
      })
      .filter((w): w is Workout => w != null);
  },

  parseEvent(event: Json, fallbackFTP: number): Workout | null {
    if (!event || typeof event !== "object") return null;
    if (typeof event.type === "string" && !rideTypes.has(event.type)) return null;
    const doc = event.workout_doc;
    if (!doc || typeof doc !== "object") return null;
    const ftp = num(doc.ftp) ?? fallbackFTP;
    const steps = IntervalsParser.flatten(Array.isArray(doc.steps) ? doc.steps : [], ftp);
    if (steps.length === 0) return null;
    const idValue = event.id;
    const eventId = typeof idValue === "number" ? idValue : typeof idValue === "string" && /^-?\d+$/.test(idValue) ? Number(idValue) : null;
    const id = eventId != null ? `event-${eventId}` : `workout-${typeof idValue === "string" ? idValue : newId()}`;
    return {
      id,
      name: typeof event.name === "string" ? event.name : "Workout",
      date: typeof event.start_date_local === "string" ? event.start_date_local : null,
      eventId: event.category != null ? eventId : null,
      description: typeof event.description === "string" ? event.description : null,
      steps,
    };
  },

  /** Expands repeats and converts every step to a fraction of FTP. */
  flatten(steps: Json[], ftp: number): WorkoutStep[] {
    const result: WorkoutStep[] = [];
    for (const step of steps) {
      if (Array.isArray(step?.steps)) {
        const reps = Math.max(1, Math.trunc(num(step.reps) ?? 1));
        const inner = IntervalsParser.flatten(step.steps, ftp);
        for (let i = 0; i < reps; i++) result.push(...inner);
        continue;
      }
      const parsed = IntervalsParser.parseStep(step, ftp);
      if (parsed) result.push(parsed);
    }
    return result;
  },

  parseStep(step: Json, ftp: number): WorkoutStep | null {
    if (!step || typeof step !== "object") return null;
    let duration = num(step.duration) ?? 0;
    if (duration <= 0) {
      const distance = num(step.distance);
      if (distance != null) duration = distance / (30 / 3.6);
    }
    if (!(duration > 0)) return null;
    const label = typeof step.text === "string" ? step.text : null;
    if (step.freeride === true) return Step.free(duration, label);
    const power = step.power;
    if (!power || typeof power !== "object") return Step.free(duration, label);
    const units = typeof power.units === "string" ? power.units.toLowerCase() : "%ftp";
    const ramp = step.ramp === true;

    const fraction = (value: number): number | null => {
      switch (units) {
        case "%ftp":
        case "percent_ftp":
          return value / 100;
        case "w":
        case "watts":
          return ftp > 0 ? value / ftp : null;
        case "power_zone":
        case "zone": {
          const i = rnd(value) - 1;
          return zoneMidpoints[Math.min(zoneMidpoints.length - 1, Math.max(0, i))];
        }
        default:
          return null;
      }
    };

    const value = num(power.value);
    if (value != null) {
      const f = fraction(value);
      if (f != null) return Step.steady(duration, f, label);
    }
    const start = num(power.start);
    const end = num(power.end);
    if (start != null && end != null) {
      const fs = fraction(start);
      const fe = fraction(end);
      if (fs != null && fe != null) {
        return ramp ? Step.ramp(duration, fs, fe, label) : Step.steady(duration, (fs + fe) / 2, label);
      }
    }
    // Fall back to resolved absolute values if present.
    const resolved = step._power;
    if (resolved && typeof resolved === "object" && ftp > 0) {
      const v = num(resolved.value);
      if (v != null) return Step.steady(duration, v / ftp, label);
      const s = num(resolved.start);
      const e = num(resolved.end);
      if (s != null && e != null) {
        return ramp ? Step.ramp(duration, s / ftp, e / ftp, label) : Step.steady(duration, (s + e) / 2 / ftp, label);
      }
    }
    return Step.free(duration, label);
  },
};

/** Athlete data from intervals.icu that the app uses. */
export interface IntervalsAthlete {
  name: string | null;
  ftp: number | null;
  weight: number | null;
  zones: number[] | null;
}

function rideSportSettings(json: Json): Json | null {
  const settings = Array.isArray(json?.sportSettings) ? json.sportSettings : [];
  return settings.find((s: Json) => Array.isArray(s?.types) && s.types.some((t: string) => rideTypes.has(t))) ?? null;
}

/** Id and FTP values of the cycling sport settings. */
export function rideSettings(json: Json): { id: number; ftp: number | null; indoorFTP: number | null } | null {
  const ride = rideSportSettings(json);
  const id = ride ? num(ride.id) : null;
  if (!ride || id == null) return null;
  const ftp = num(ride.ftp);
  const indoor = num(ride.indoor_ftp);
  return { id: Math.trunc(id), ftp: ftp != null ? rnd(ftp) : null, indoorFTP: indoor != null ? rnd(indoor) : null };
}

export function parseAthlete(json: Json): IntervalsAthlete {
  const athlete: IntervalsAthlete = { name: null, ftp: null, weight: null, zones: null };
  if (!json || typeof json !== "object") return athlete;
  athlete.name = typeof json.name === "string" ? json.name : null;
  athlete.weight = num(json.icu_weight) ?? num(json.weight);
  const ride = rideSportSettings(json);
  if (ride) {
    const ftp = num(ride.indoor_ftp) ?? num(ride.ftp);
    athlete.ftp = ftp != null ? rnd(ftp) : null;
    if (Array.isArray(ride.power_zones)) {
      const values = ride.power_zones.map(num).filter((v: number | null): v is number => v != null);
      if (values.length >= 5) athlete.zones = values.slice(0, 5);
    }
  }
  return athlete;
}

export function zonesOf(bounds: number[] | null | undefined): PowerZones {
  return new PowerZones(bounds && bounds.length >= 5 ? bounds : undefined);
}
