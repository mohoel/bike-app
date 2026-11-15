import { clamp } from "./basics";

export interface GradeRange {
  min: number;
  max: number;
}

export type CoursePreset = "flat" | "rolling" | "hilly" | "mountainous" | "custom";

export const coursePresets: { id: CoursePreset; title: string; range: GradeRange | null }[] = [
  { id: "flat", title: "Flach", range: { min: 0, max: 2 } },
  { id: "rolling", title: "Wellig", range: { min: -3, max: 4 } },
  { id: "hilly", title: "Hügelig", range: { min: -5, max: 7 } },
  { id: "mountainous", title: "Bergig", range: { min: -6, max: 10 } },
  { id: "custom", title: "Eigene", range: null },
];

export function coursePreset(id: CoursePreset) {
  return coursePresets.find((p) => p.id === id) ?? coursePresets[2];
}

const MASK = (1n << 64n) - 1n;

/** Small, fast, deterministic random number generator (SplitMix64). */
export class SplitMix64 {
  private state: bigint;

  constructor(seed: number | bigint) {
    this.state = BigInt(seed) & MASK;
  }

  next(): bigint {
    this.state = (this.state + 0x9e3779b97f4a7c15n) & MASK;
    let z = this.state;
    z = ((z ^ (z >> 30n)) * 0xbf58476d1ce4e5b9n) & MASK;
    z = ((z ^ (z >> 27n)) * 0x94d049bb133111ebn) & MASK;
    return z ^ (z >> 31n);
  }

  /** Uniform value in [0, 1). */
  unit(): number {
    return Number(this.next() >> 11n) / 2 ** 53;
  }
}

export interface ProfileColumn {
  /** Height within the shown window, 0 = lowest point, 1 = highest point. */
  norm: number;
  /** Average grade of the column in percent. */
  grade: number;
}

/**
 * Procedurally generated course: a function from distance to grade and elevation.
 *
 * The course is made of segments of 200–1500 m with a random target grade inside
 * the chosen range. Grades blend smoothly between segments. For ranges with climbs
 * and descents, the generator leans towards descending when the course is high and
 * towards climbing when it is low, so a long ride does not only go uphill.
 * New samples are generated on demand, so rides by duration have no fixed length.
 */
export class ElevationProfile {
  static readonly spacing = 50;

  readonly range: GradeRange;
  readonly seed: number;
  grades: number[] = [];
  endElevations: number[] = [];

  private rng: SplitMix64;
  private target = 0;
  private remaining = 0;
  private current = 0;
  private height = 0;
  private readonly bandCenter: number;
  private readonly bandScale: number;

  constructor(range: GradeRange, seed: number) {
    this.range = { min: Math.min(range.min, range.max), max: Math.max(range.min, range.max) };
    this.seed = seed;
    this.rng = new SplitMix64(seed);
    const span = Math.max(1, this.range.max - this.range.min);
    this.bandCenter = (120 * span) / 16;
    this.bandScale = (400 * span) / 16;
    this.current = Math.min(Math.max(0, this.range.min), this.range.max);
  }

  /** Makes sure samples exist up to `distance` metres. */
  ensure(distance: number): void {
    const needed = Math.ceil(Math.max(0, distance) / ElevationProfile.spacing) + 1;
    while (this.grades.length < needed) this.generateSample();
  }

  private generateSample(): void {
    if (this.remaining <= 0) {
      this.target = this.nextTarget();
      this.remaining = 200 + this.rng.unit() * 1300;
    }
    this.remaining -= ElevationProfile.spacing;
    this.current += (this.target - this.current) * 0.15;
    this.current = clamp(this.current, this.range.min, this.range.max);
    this.grades.push(this.current);
    this.height += (this.current / 100) * ElevationProfile.spacing;
    this.endElevations.push(this.height);
  }

  private nextTarget(): number {
    const { min, max } = this.range;
    if (min >= 0 || max <= 0) return min + this.rng.unit() * (max - min);
    const pUp = clamp(0.55 - (this.height - this.bandCenter) / this.bandScale, 0.2, 0.8);
    if (this.rng.unit() < pUp) return this.rng.unit() * max;
    return this.rng.unit() * min;
  }

  private index(distance: number): number {
    const d = Math.max(0, distance);
    this.ensure(d + ElevationProfile.spacing);
    return Math.min(this.grades.length - 1, Math.floor(d / ElevationProfile.spacing));
  }

  /** Grade in percent at a distance in metres. */
  grade(distance: number): number {
    return this.grades[this.index(distance)];
  }

  /** Elevation in metres relative to the start. */
  elevation(distance: number): number {
    const d = Math.max(0, distance);
    const i = this.index(d);
    const start = i === 0 ? 0 : this.endElevations[i - 1];
    return start + (this.grades[i] / 100) * (d - i * ElevationProfile.spacing);
  }

  /** Climbing in metres from the start up to `distance`. */
  ascent(distance: number): number {
    const d = Math.max(0, distance);
    const last = this.index(d);
    let sum = 0;
    for (let i = 0; i <= last; i++) {
      const segment = i === last ? d - i * ElevationProfile.spacing : ElevationProfile.spacing;
      if (this.grades[i] > 0) sum += (this.grades[i] / 100) * segment;
    }
    return sum;
  }

  /** Average grade in percent over `length` metres starting at `distance`. */
  averageGrade(distance: number, length: number): number {
    if (!(length > 0)) return this.grade(distance);
    return ((this.elevation(distance + length) - this.elevation(distance)) / length) * 100;
  }

  /** Columns for a bar-style profile between two distances. */
  columns(start: number, end: number, count: number, minimumSpan = 30): ProfileColumn[] {
    if (!(count > 0) || !(end > start)) return [];
    this.ensure(end + ElevationProfile.spacing);
    const width = (end - start) / count;
    const raw: { elevation: number; grade: number }[] = [];
    for (let k = 0; k < count; k++) {
      const a = start + k * width;
      const b = a + width;
      const mid = (a + b) / 2;
      const lo = Math.max(0, a);
      const hi = Math.max(0, b);
      const g = hi > lo ? ((this.elevation(hi) - this.elevation(lo)) / (hi - lo)) * 100 : 0;
      raw.push({ elevation: this.elevation(Math.max(0, mid)), grade: g });
    }
    const lo = Math.min(...raw.map((r) => r.elevation));
    const hi = Math.max(...raw.map((r) => r.elevation));
    const span = Math.max(hi - lo, minimumSpan);
    return raw.map((r) => ({ norm: (r.elevation - lo) / span, grade: r.grade }));
  }
}
