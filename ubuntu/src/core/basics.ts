// Formatting, colours, physics, gears and power zones (ported from the macOS app).

/** Rounds half away from zero, like Swift's `rounded()`. */
export function rnd(x: number): number {
  return Math.sign(x) * Math.round(Math.abs(x));
}

export function clamp(x: number, lo: number, hi: number): number {
  return Math.min(hi, Math.max(lo, x));
}

const pad2 = (n: number) => String(n).padStart(2, "0");

/** German number formatting. */
export const Fmt = {
  decimal(value: number, digits = 1): string {
    return value.toFixed(digits).replace(".", ",");
  },
  /** 0:42:10 (always with hours) or 32:46. */
  clock(seconds: number, hours: boolean): string {
    const s = Math.floor(Math.max(0, seconds));
    const h = Math.floor(s / 3600);
    const m = Math.floor((s % 3600) / 60);
    const sec = s % 60;
    if (hours || h > 0) return `${h}:${pad2(m)}:${pad2(sec)}`;
    return `${m}:${pad2(sec)}`;
  },
  km(meters: number): string {
    return Fmt.decimal(meters / 1000, 1);
  },
  signedGrade(grade: number): string {
    return (grade < -0.05 ? "−" : "") + Fmt.decimal(Math.abs(grade), 1);
  },
};

// MARK: Theme

export const Theme = {
  accent: "#FF6B1A",
  accentSoft: "#FF8A3D",
  onAccent: "#170A02",
  background: "#0B0D12",
  tile: "#151821",
  track: "#1E222C",
  chip: "#1B1F29",
  barBase: "#0E1016",
  label: "rgba(255,255,255,0.62)",
  secondary: "rgba(255,255,255,0.66)",
  heart: "#FF5C7A",
  ok: "#3BD16F",
  warn: "#FFD23F",
  bad: "#FF4545",
  intervals: "#6CB4FF",
  /** Z1…Z6: grey, blue, green, yellow, orange, red. */
  zoneColors: ["#A3ACB9", "#3D9BFF", "#3BD16F", "#FFD23F", "#FF8A1F", "#FF4545"],
  zoneColor(index: number): string {
    return Theme.zoneColors[clamp(index, 0, Theme.zoneColors.length - 1)];
  },
  /** Descent teal, flat green, 3–6 % yellow, 6–9 % orange, above red. */
  gradeColor(grade: number): string {
    if (grade < -1) return "#2ED3C6";
    if (grade < 3) return "#3BD16F";
    if (grade < 6) return "#FFD23F";
    if (grade < 9) return "#FF8A1F";
    return "#FF4545";
  },
  complianceColor(c: TargetCompliance): string {
    return c === "inTarget" ? Theme.ok : c === "tooLow" ? Theme.warn : Theme.bad;
  },
  gradeLegend(): { label: string; color: string }[] {
    return [
      { label: "Abfahrt", color: Theme.gradeColor(-3) },
      { label: "0–3 %", color: Theme.gradeColor(1) },
      { label: "3–6 %", color: Theme.gradeColor(4) },
      { label: "6–9 %", color: Theme.gradeColor(7) },
      { label: "über 9 %", color: Theme.gradeColor(10) },
    ];
  },
};

// MARK: Physics

export interface RiderParameters {
  riderMass: number;
  bikeMass: number;
  crr: number;
  cda: number;
  airDensity: number;
  drivetrainEfficiency: number;
  wheelCircumference: number;
}

export function riderParameters(riderMass = 75, bikeMass = 8): RiderParameters {
  return { riderMass, bikeMass, crr: 0.004, cda: 0.32, airDensity: 1.2, drivetrainEfficiency: 0.98, wheelCircumference: 2.096 };
}

const totalMass = (r: RiderParameters) => r.riderMass + r.bikeMass;

/** Road cycling physics used for the virtual speed and for trainer resistance. */
export const BikePhysics = {
  gravity: 9.81,
  /** Extra mass that models the rotating wheels. */
  wheelInertiaMass: 1.5,

  /** Rolling, gravity and air resistance in newtons (negative when rolling downhill). */
  resistiveForce(speed: number, gradePercent: number, rider: RiderParameters): number {
    const theta = Math.atan(gradePercent / 100);
    const slope = totalMass(rider) * BikePhysics.gravity * (rider.crr * Math.cos(theta) + Math.sin(theta));
    const air = 0.5 * rider.airDensity * rider.cda * speed * speed;
    return slope + air;
  },

  /** Power at the pedals needed to hold a speed. */
  powerRequired(speed: number, gradePercent: number, rider: RiderParameters): number {
    const p = BikePhysics.resistiveForce(speed, gradePercent, rider) * speed;
    return Math.max(0, p) / rider.drivetrainEfficiency;
  },

  /** Speed in m/s that a constant power holds on a constant grade. */
  steadySpeed(power: number, gradePercent: number, rider: RiderParameters): number {
    const wheelPower = Math.max(0, power) * rider.drivetrainEfficiency;
    const f = (v: number) => BikePhysics.resistiveForce(v, gradePercent, rider) * v - wheelPower;
    let lo = 1e-4;
    let hi = 60.0;
    if (f(lo) >= 0) return 0;
    for (let i = 0; i < 60; i++) {
      const mid = (lo + hi) / 2;
      if (f(mid) > 0) hi = mid;
      else lo = mid;
    }
    return lo;
  },

  /** Integrates the speed over `dt` seconds using the energy balance. */
  advance(speed: number, power: number, gradePercent: number, dt: number, rider: RiderParameters): number {
    const mass = totalMass(rider) + BikePhysics.wheelInertiaMass;
    const force = BikePhysics.resistiveForce(speed, gradePercent, rider);
    const energy = 0.5 * mass * speed * speed + (Math.max(0, power) * rider.drivetrainEfficiency - force * speed) * dt;
    return Math.sqrt(Math.max(0, (2 * energy) / mass));
  },
};

// MARK: Gears

export type ShiftDirection = "up" | "down";

/** 24 virtual gears, similar in range to Zwift's virtual shifting. */
export class VirtualGearbox {
  static readonly ratios = [
    0.75, 0.87, 0.99, 1.11, 1.23, 1.38, 1.53, 1.68, 1.86, 2.04, 2.22, 2.4, 2.61, 2.82, 3.03, 3.24, 3.49, 3.74, 3.98, 4.23, 4.54,
    4.85, 5.16, 5.49,
  ];
  static readonly count = VirtualGearbox.ratios.length;

  gear: number;

  constructor(gear = 12) {
    this.gear = clamp(gear, 1, VirtualGearbox.count);
  }

  get ratio(): number {
    return VirtualGearbox.ratios[this.gear - 1];
  }

  /** Shifts one gear. "up" means harder. Returns false at the end of the range. */
  shift(direction: ShiftDirection): boolean {
    if (direction === "up") {
      if (this.gear >= VirtualGearbox.count) return false;
      this.gear += 1;
    } else {
      if (this.gear <= 1) return false;
      this.gear -= 1;
    }
    return true;
  }
}

// MARK: Power zones

export const standardZoneBounds = [55, 75, 90, 105, 120];
export const zoneNames = ["Erholung", "Grundlage", "Tempo", "Schwelle", "VO2max", "Anaerob"];

/** Power zones as upper bounds in percent of FTP (defaults match intervals.icu). */
export class PowerZones {
  constructor(public upperBounds: number[] = standardZoneBounds) {}

  /** Zone index 0…5 for a fraction of FTP. */
  indexForFraction(fraction: number): number {
    const percent = fraction * 100;
    for (let i = 0; i < this.upperBounds.length; i++) {
      if (percent < this.upperBounds[i] + 0.5) return i;
    }
    return Math.min(5, this.upperBounds.length);
  }

  index(watts: number, ftp: number): number {
    if (!(ftp > 0)) return 0;
    return this.indexForFraction(watts / ftp);
  }

  static shortName(index: number): string {
    return `Z${index + 1}`;
  }

  static zoneName(index: number): string {
    return zoneNames[clamp(index, 0, zoneNames.length - 1)];
  }
}

/** How well the current power matches a workout target. */
export type TargetCompliance = "inTarget" | "tooLow" | "tooHigh";

export function compliance(watts: number, target: number, tolerance = 0.05): TargetCompliance {
  if (!(target > 0)) return "inTarget";
  const ratio = watts / target;
  if (Math.abs(ratio - 1) <= tolerance) return "inTarget";
  return ratio < 1 ? "tooLow" : "tooHigh";
}

export function complianceLabel(c: TargetCompliance): string {
  return c === "inTarget" ? "IM ZIEL" : c === "tooLow" ? "ZU NIEDRIG" : "ZU HOCH";
}
