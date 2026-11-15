// Session config, resistance strategies and the ride engine.
import { BikePhysics, Fmt, RiderParameters, ShiftDirection, VirtualGearbox, clamp, rnd } from "./basics";
import { LiveSensors, TrainerCommand, commandsClose, neutralCommand } from "./ble";
import { ElevationProfile, GradeRange, ProfileColumn, SplitMix64 } from "./elevation";
import { RideRecorder } from "./ride";
import { FTPTestPlan, FTPTestResult, FTPTestTracker, Workout, WorkoutPlayer, WorkoutPosition, truncatedTestWorkout, Step } from "./workout";

export type DisplayMode = "bar" | "fullscreen";
export type GoalKind = "distance" | "duration";

export type SessionGoal = { kind: "distance"; meters: number } | { kind: "duration"; seconds: number } | { kind: "workout" };

/** Step for quick goal changes: 5 km or 5 minutes. */
export const goalDistanceStep = 5000;
export const goalDurationStep = 300;

export function goalLabel(goal: SessionGoal): string {
  if (goal.kind === "distance") return `${Fmt.km(goal.meters)} km`;
  if (goal.kind === "duration") return `${rnd(goal.seconds / 60)} min`;
  return "Workout";
}

/** How a structured workout drives the trainer. */
export type WorkoutMode = "ergOffset" | "ergGears" | "simTargets";

export const workoutModes: { id: WorkoutMode; title: string; detail: string }[] = [
  { id: "ergOffset", title: "ERG · Click ±5 W", detail: "Der Kickr hält die Zielwatt. Mit Click + und − verschiebst du die Intensität in 5-W-Schritten." },
  { id: "ergGears", title: "ERG · Click = Gang", detail: "Der Kickr hält die Zielwatt. Click schaltet Gänge, die in Freifahrt-Abschnitten wirken." },
  {
    id: "simTargets",
    title: "Sim mit Zielen",
    detail: "Kein ERG: Du fährst das zufällige Höhenprofil und schaltest selbst, die Ziele werden nur angezeigt.",
  },
];

export const workoutModeTitle = (mode: WorkoutMode) => workoutModes.find((m) => m.id === mode)!.title;

/** How the app turns virtual gears and slope into trainer commands. */
export type ResistanceMode = "matchedSimulation" | "ergVirtual";

export const resistanceModes: { id: ResistanceMode; title: string; detail: string }[] = [
  {
    id: "matchedSimulation",
    title: "Simulation",
    detail: "Der Trainer bekommt Steigung, Rollwiderstand und Luftwiderstand passend zum Gang. Fühlt sich am natürlichsten an.",
  },
  {
    id: "ergVirtual",
    title: "ERG",
    detail: "Die App rechnet aus Gang und Trittfrequenz die nötigen Watt und stellt sie per ERG ein. Reagiert etwas träger.",
  },
];

export interface SessionConfig {
  name: string;
  courseTitle: string;
  gradeRange: GradeRange;
  seed: number;
  goal: SessionGoal;
  workout: Workout | null;
  workoutMode: WorkoutMode;
  /** "Hügelig" etc., used for the activity name. */
  presetTitle: string;
  /** Set for FTP tests; the workout is the test's steps. */
  test: FTPTestPlan | null;
}

/** True when the course profile matters for resistance and display. */
export function usesCourse(config: SessionConfig): boolean {
  return config.workout == null || config.workoutMode === "simTargets";
}

// MARK: - Resistance

export interface ResistanceInput {
  gradePercent: number;
  difficulty: number;
  virtualRatio: number;
  trainerRatio: number;
  cadence: number;
  rider: RiderParameters;
}

/**
 * Makes the trainer's own physics behave like the virtual gear.
 *
 * With the Zwift Cog the trainer always spins in the same real gear. A harder virtual
 * gear means the virtual bike rolls k times faster than the trainer thinks it does,
 * where k = virtual ratio / real ratio. The trainer computes its resistance as
 *   P = (m·g·(crr + sin θ) + ½·cw·v²)·v
 * from its own speed v. Scaling crr and the slope by k and the wind coefficient by k³
 * gives exactly the power the virtual bike would need at speed k·v, so shifting and
 * climbing feel right without waiting for the app.
 */
export function matchedSimulationCommand(input: ResistanceInput): TrainerCommand {
  const k = clamp(input.virtualRatio / Math.max(0.1, input.trainerRatio), 0.2, 3.0);
  const effectiveGrade = input.gradePercent * input.difficulty;
  const sinTheta = Math.sin(Math.atan(effectiveGrade / 100));
  const crr = clamp(k * input.rider.crr, 0, 0.0254);
  const linear = k * (input.rider.crr + sinTheta);
  const sinTrainer = clamp(linear - crr, -0.35, 0.35);
  const grade = clamp(Math.tan(Math.asin(sinTrainer)) * 100, -15, 20);
  const wind = Math.min(2.54, input.rider.airDensity * input.rider.cda * k * k * k);
  return { kind: "sim", gradePercent: grade, crr, windResistance: wind };
}

/** Computes the power the virtual bike needs at the current cadence and gear and sets it in ERG mode. */
export function ergVirtualCommand(input: ResistanceInput): TrainerCommand {
  const speed = (input.cadence / 60) * input.virtualRatio * input.rider.wheelCircumference;
  const grade = input.gradePercent * input.difficulty;
  const watts = BikePhysics.powerRequired(speed, grade, input.rider);
  return { kind: "erg", watts: rnd(clamp(watts, 0, 1200)) };
}

/** Learns the real gear ratio from trainer speed and cadence while riding steadily. */
export class TrainerRatioCalibrator {
  estimate: number | null = null;
  samples = 0;

  get isCalibrated(): boolean {
    return this.samples >= 40;
  }

  add(trainerSpeed: number, cadence: number, wheelCircumference: number): void {
    if (!(cadence > 55 && cadence < 130 && trainerSpeed > 2)) return;
    const ratio = (trainerSpeed * 60) / (cadence * wheelCircumference);
    if (!(ratio > 0.8 && ratio < 6)) return;
    this.estimate = this.estimate == null ? ratio : this.estimate + (ratio - this.estimate) * 0.05;
    this.samples += 1;
  }
}

// MARK: - Engine

export type RidePhase = "waiting" | "riding" | "paused" | "finished";

export interface PowerPoint {
  time: number;
  watts: number;
}

/** What the engine needs from the settings. */
export interface EngineSettings {
  rider: RiderParameters;
  difficulty: number;
  resistanceMode: ResistanceMode;
  startGear: number;
  /** Gear ratio of the real drivetrain on the trainer. */
  trainerRatio: number;
  measuredTrainerRatio: number;
  setMeasuredTrainerRatio(ratio: number): void;
}

/** What the engine needs from Bluetooth. */
export interface EngineDevices {
  live: LiveSensors;
  send(command: TrainerCommand): void;
  hasMotionData(now: number): boolean;
  trainerSupportsSimulation: boolean;
}

export const baseAltitude = 240;

/** Runs a ride: reads sensors, integrates virtual speed and distance, drives the trainer, records data. */
export class RideEngine {
  config: SessionConfig;
  readonly profile: ElevationProfile;
  player: WorkoutPlayer | null;
  /** FTP test progress (null for normal rides). */
  testTracker: FTPTestTracker | null;
  testResult: FTPTestResult | null = null;
  onTestResult: ((result: FTPTestResult) => void) | null = null;
  onFinish: ((engine: RideEngine) => void) | null = null;
  readonly recorder = new RideRecorder();

  phase: RidePhase = "waiting";
  manualPause = false;
  startDate: number;
  endDate: number | null = null;
  movingTime = 0;
  distance = 0;
  /** Virtual speed in m/s. */
  speed = 0;
  power3s = 0;
  cadence = 0;
  heartRate: number | null = null;
  /** Smoothed course grade in percent. */
  gradePercent = 0;
  gearbox: VirtualGearbox;
  ergOffset = 0;
  shiftCount = 0;
  targetWatts: number | null = null;
  stepIndex: number | null = null;
  barColumns: ProfileColumn[] = [];
  barMarker = 0;
  fullColumns: ProfileColumn[] = [];
  fullMarker = 0;
  fullWindow: [number, number] = [0, 1];
  powerTrace: PowerPoint[] = [];
  /** No trainer and no cadence data: the clock runs on its own, pause only by hand. */
  sensorless = false;
  /** No trainer power: speed comes from cadence and the virtual gear. */
  speedFromCadence = false;

  private timer: ReturnType<typeof setInterval> | null = null;
  private lastTick: number | null = null;
  private idleTime = 0;
  private powerWindow: { time: number; watts: number }[] = [];
  private lastCommand: TrainerCommand | null = null;
  private lastCommandAt = -Infinity;
  private nextSampleAt = 1;
  private calibrator = new TrainerRatioCalibrator();
  private traceSum = 0;
  private traceCount = 0;

  constructor(
    config: SessionConfig,
    private readonly settings: EngineSettings,
    private readonly devices: EngineDevices,
    private readonly ftpProvider: () => number,
    private readonly now: () => number = Date.now,
  ) {
    this.config = config;
    this.startDate = now();
    this.profile = new ElevationProfile(config.gradeRange, config.seed);
    this.player = config.workout ? new WorkoutPlayer(config.workout) : null;
    this.testTracker = config.test ? new FTPTestTracker(config.test) : null;
    this.gearbox = new VirtualGearbox(settings.startGear);
    if (config.goal.kind === "distance") this.profile.ensure(config.goal.meters + 500);
    this.refreshColumns();
  }

  get ftp(): number {
    return this.ftpProvider();
  }

  // MARK: Lifecycle

  /** Starts the ride. `autoTick: false` lets tests drive `tick()` themselves. */
  start(autoTick = true): void {
    this.startDate = this.now();
    this.lastTick = null;
    if (this.timer) clearInterval(this.timer);
    this.timer = autoTick ? setInterval(() => this.tick(), 250) : null;
    this.updateWorkoutTarget();
    this.applyResistance(true);
  }

  togglePause(): void {
    if (this.phase === "riding" || this.phase === "waiting") {
      this.phase = "paused";
      this.manualPause = true;
    } else if (this.phase === "paused") {
      this.manualPause = false;
      this.phase = "riding";
      this.idleTime = 0;
    }
  }

  finish(): void {
    if (this.phase === "finished") return;
    this.phase = "finished";
    if (this.timer) clearInterval(this.timer);
    this.timer = null;
    const now = this.now();
    this.endDate = now;
    // Ending the session during a test effort still evaluates it (an aborted 20 minutes is flagged).
    const tracker = this.testTracker;
    if (tracker && !tracker.finished && this.movingTime >= (this.config.test?.effortStart ?? Infinity)) {
      tracker.endManually();
      if (tracker.result) {
        this.testResult = tracker.result;
        this.onTestResult?.(tracker.result);
      }
    }
    this.recorder.finish(now, this.movingTime);
    if (this.settings.measuredTrainerRatio <= 0 && this.calibrator.isCalibrated && this.calibrator.estimate != null) {
      this.settings.setMeasuredTrainerRatio(this.calibrator.estimate);
    }
    this.devices.send(neutralCommand);
    this.onFinish?.(this);
  }

  shift(direction: ShiftDirection): void {
    if (this.phase === "finished") return;
    if (this.clickAdjustsErgOffset) {
      this.ergOffset = clamp(this.ergOffset + (direction === "up" ? 5 : -5), -150, 150);
      this.updateWorkoutTarget();
    } else if (!this.gearbox.shift(direction)) {
      return;
    }
    this.shiftCount += 1;
    this.applyResistance(true);
  }

  // MARK: FTP test

  get isTest(): boolean {
    return this.config.test != null;
  }

  /** True during the evaluated part of a test. */
  get isInTestEffort(): boolean {
    return this.testTracker?.isInEffort(this.movingTime) ?? false;
  }

  /** The ramp can be ended by the rider ("I'm done"); the 20 minutes run to the end. */
  get canEndTestEffort(): boolean {
    return this.config.test?.kind === "ramp" && this.isInTestEffort;
  }

  get testEstimate(): number | null {
    return this.testResult?.ftp ?? this.testTracker?.estimate ?? null;
  }

  /** Ends the ramp now: evaluates it and continues with the cooldown. */
  endTestEffort(): void {
    const tracker = this.testTracker;
    if (!tracker || tracker.finished || this.movingTime < (this.config.test?.effortStart ?? Infinity)) return;
    tracker.endManually();
    this.testEffortEnded();
  }

  private testEffortEnded(): void {
    const result = this.testTracker?.result;
    const plan = this.config.test;
    if (!result || !plan) return;
    this.testResult = result;
    if (plan.kind === "ramp" && this.player && this.movingTime < plan.effortEnd) {
      // Replace the rest of the ramp with the cooldown.
      const shortened = truncatedTestWorkout(this.player.workout, this.movingTime);
      this.config = { ...this.config, workout: shortened };
      this.player = new WorkoutPlayer(shortened);
      this.updateWorkoutTarget();
      this.applyResistance(true);
    }
    this.onTestResult?.(result);
  }

  // MARK: Goal

  /** Free rides can change their goal while riding; workouts end with the workout. */
  get canChangeGoal(): boolean {
    return this.player == null && this.phase !== "finished";
  }

  /** Sets a new distance or duration goal. A goal already behind the rider is moved just ahead. */
  setGoal(goal: SessionGoal): void {
    if (!this.canChangeGoal) return;
    if (goal.kind === "distance") {
      const minimum = Math.ceil((this.distance + 500) / 1000) * 1000;
      const target = Math.max(goal.meters, minimum);
      this.profile.ensure(target + 500);
      this.config = { ...this.config, goal: { kind: "distance", meters: target } };
    } else if (goal.kind === "duration") {
      const minimum = Math.ceil((this.movingTime + 60) / 60) * 60;
      this.config = { ...this.config, goal: { kind: "duration", seconds: Math.max(goal.seconds, minimum) } };
    } else {
      return;
    }
    // The shown course changes with the goal.
    this.barColumns = [];
    this.fullColumns = [];
    this.refreshColumns();
  }

  /** Lengthens (+1) or shortens (−1) the goal by 5 km or 5 minutes. */
  adjustGoal(steps: number): void {
    const goal = this.config.goal;
    if (goal.kind === "distance") {
      const next = (rnd(goal.meters / goalDistanceStep) + steps) * goalDistanceStep;
      this.setGoal({ kind: "distance", meters: Math.max(goalDistanceStep, next) });
    } else if (goal.kind === "duration") {
      const next = (rnd(goal.seconds / goalDurationStep) + steps) * goalDurationStep;
      this.setGoal({ kind: "duration", seconds: Math.max(goalDurationStep, next) });
    }
  }

  // MARK: Derived state

  get isWorkout(): boolean {
    return this.player != null;
  }

  get usesCourse(): boolean {
    return usesCourse(this.config);
  }

  /** The trainer is in ERG mode right now (workout step with a target). */
  get isErgActive(): boolean {
    if (this.config.workoutMode === "simTargets" || !this.player) return false;
    const step = this.player.position(this.movingTime)?.step;
    return step != null && Step.hasTarget(step);
  }

  get clickAdjustsErgOffset(): boolean {
    return this.config.workoutMode === "ergOffset" && this.isErgActive;
  }

  get workoutPosition(): WorkoutPosition | null {
    return this.player?.position(this.movingTime) ?? null;
  }

  get remainingDistance(): number | null {
    return this.config.goal.kind === "distance" ? Math.max(0, this.config.goal.meters - this.distance) : null;
  }

  get remainingTime(): number | null {
    const goal = this.config.goal;
    if (goal.kind === "duration") return Math.max(0, goal.seconds - this.movingTime);
    if (goal.kind === "workout") return Math.max(0, (this.player?.duration ?? 0) - this.movingTime);
    return null;
  }

  /** 0…1 progress towards the goal. */
  get progress(): number {
    const goal = this.config.goal;
    if (goal.kind === "distance") return goal.meters > 0 ? Math.min(1, this.distance / goal.meters) : 0;
    if (goal.kind === "duration") return goal.seconds > 0 ? Math.min(1, this.movingTime / goal.seconds) : 0;
    const total = this.player?.duration ?? 0;
    return total > 0 ? Math.min(1, this.movingTime / total) : 0;
  }

  get altitude(): number {
    return baseAltitude + this.profile.elevation(this.distance);
  }

  get ascent(): number {
    return this.usesCourse ? this.profile.ascent(this.distance) : 0;
  }

  get nextKilometerGrade(): number {
    return this.profile.averageGrade(this.distance, 1000);
  }

  // MARK: Tick

  tick(): void {
    const now = this.now();
    const dt = this.lastTick == null ? 0.25 : clamp((now - this.lastTick) / 1000, 0, 1);
    this.lastTick = now;
    const live = this.devices.live;
    const rawPower = live.power(now) ?? 0;
    const rawCadence = live.cadence(now) ?? 0;
    this.heartRate = live.heartRate(now);
    this.cadence = rnd(rawCadence);
    this.updatePowerAverage(rawPower, now);
    const trainerSpeed = live.trainerSpeed(now);
    if (trainerSpeed != null && live.trainerCadence != null) {
      this.calibrator.add(trainerSpeed, live.trainerCadence, this.settings.rider.wheelCircumference);
    }

    // Without trainer and cadence sensor the ride is a plain timer (after a short grace period at the start).
    this.sensorless = !this.devices.hasMotionData(now) && (now - this.startDate) / 1000 > 5;
    this.speedFromCadence = live.power(now) == null && rawCadence > 0;
    const pedaling = this.sensorless || rawPower > 15 || rawCadence > 20;
    switch (this.phase) {
      case "waiting":
        if (pedaling) {
          this.phase = "riding";
          this.idleTime = 0;
        }
        break;
      case "riding":
        this.idleTime = pedaling ? 0 : this.idleTime + dt;
        if (this.canEndTestEffort && this.idleTime >= 2) {
          // Stopping during the ramp means "done", not "pause".
          this.endTestEffort();
        } else if (this.idleTime >= 3) {
          this.phase = "paused";
        }
        break;
      case "paused":
        if (!this.manualPause && pedaling) {
          this.phase = "riding";
          this.idleTime = 0;
        }
        break;
      case "finished":
        return;
    }

    const rider = this.settings.rider;
    if (this.phase === "riding") {
      this.movingTime += dt;
      const physicsGrade = this.usesCourse ? this.gradePercent : 0;
      if (this.speedFromCadence) {
        // No power from a trainer: roll as fast as the virtual gear and the cadence say.
        const target = (rawCadence / 60) * this.gearbox.ratio * rider.wheelCircumference;
        this.speed += (target - this.speed) * Math.min(1, dt * 2);
      } else {
        this.speed = BikePhysics.advance(this.speed, rawPower, physicsGrade, dt, rider);
      }
      this.distance += this.speed * dt;
    } else {
      this.speed = 0;
    }

    // Course grade, limited to 0.5 %/s so the trainer does not jerk.
    if (this.usesCourse) {
      const raw = this.profile.grade(this.distance);
      const maxStep = 0.5 * dt;
      this.gradePercent += clamp(raw - this.gradePercent, -maxStep, maxStep);
    } else {
      this.gradePercent = 0;
    }

    this.updateWorkoutTarget();
    this.applyResistance();

    if (this.phase === "riding" && this.movingTime >= this.nextSampleAt) {
      this.nextSampleAt += 1;
      this.recordSample(now, rawPower);
      this.refreshColumns();
    }
    this.checkGoal();
  }

  private updatePowerAverage(watts: number, now: number): void {
    this.powerWindow.push({ time: now, watts });
    this.powerWindow = this.powerWindow.filter((p) => (now - p.time) / 1000 <= 3);
    const total = this.powerWindow.reduce((s, p) => s + p.watts, 0);
    this.power3s = this.powerWindow.length === 0 ? 0 : rnd(total / this.powerWindow.length);
  }

  private updateWorkoutTarget(): void {
    const player = this.player;
    if (!player) {
      this.targetWatts = null;
      this.stepIndex = null;
      return;
    }
    const position = player.position(this.movingTime);
    if (position && position.index !== this.stepIndex) {
      if (this.stepIndex != null) this.recorder.markLap(this.now(), this.movingTime);
      this.stepIndex = position.index;
    }
    const fraction = player.targetFraction(this.movingTime);
    if (fraction != null) {
      const offset = this.config.workoutMode === "ergOffset" ? this.ergOffset : 0;
      this.targetWatts = Math.max(0, rnd(fraction * this.ftp) + offset);
    } else {
      this.targetWatts = null;
    }
  }

  /** Sends the current resistance again, e.g. after the trainer reconnected. */
  resendResistance(): void {
    if (this.phase !== "finished") this.applyResistance(true);
  }

  private applyResistance(force = false): void {
    let command: TrainerCommand;
    if (this.isErgActive && this.targetWatts != null) {
      command = { kind: "erg", watts: this.targetWatts };
    } else {
      const input: ResistanceInput = {
        gradePercent: this.gradePercent,
        difficulty: this.settings.difficulty,
        virtualRatio: this.gearbox.ratio,
        trainerRatio: this.calibrator.isCalibrated ? this.calibrator.estimate ?? this.settings.trainerRatio : this.settings.trainerRatio,
        cadence: this.cadence,
        rider: this.settings.rider,
      };
      // Trainers without slope simulation get the gears as ERG targets.
      const mode = this.devices.trainerSupportsSimulation ? this.settings.resistanceMode : "ergVirtual";
      command = mode === "matchedSimulation" ? matchedSimulationCommand(input) : ergVirtualCommand(input);
    }
    const now = this.now();
    const changed = this.lastCommand ? !commandsClose(command, this.lastCommand) : true;
    const sinceLast = (now - this.lastCommandAt) / 1000;
    const keepAlive = sinceLast > 5;
    if (!(force || changed || keepAlive)) return;
    if (!(force || sinceLast >= 0.24)) return;
    this.devices.send(command);
    this.lastCommand = command;
    this.lastCommandAt = now;
  }

  private recordSample(now: number, power: number): void {
    this.recorder.add({
      timestamp: now,
      elapsed: this.movingTime,
      power,
      cadence: this.cadence > 0 ? this.cadence : null,
      heartRate: this.heartRate,
      speed: this.speed,
      distance: this.distance,
      altitude: this.altitude,
      gradePercent: this.usesCourse ? this.gradePercent : 0,
    });
    this.traceSum += power;
    this.traceCount += 1;
    if (this.traceCount >= 5) {
      this.powerTrace.push({ time: this.movingTime, watts: this.traceSum / this.traceCount });
      this.traceSum = 0;
      this.traceCount = 0;
    }
    const tracker = this.testTracker;
    if (tracker && !tracker.finished) {
      if (tracker.add(this.movingTime, power, this.cadence, this.targetWatts)) this.testEffortEnded();
    }
  }

  private checkGoal(): void {
    const goal = this.config.goal;
    if (goal.kind === "distance") {
      if (this.distance >= goal.meters) this.finish();
    } else if (goal.kind === "duration") {
      if (this.movingTime >= goal.seconds) this.finish();
    } else if (this.player && this.movingTime >= this.player.duration) {
      this.finish();
    }
  }

  /** Profile columns for the bar (110) and the full screen view (262). */
  private refreshColumns(): void {
    if (!this.usesCourse) {
      this.barColumns = [];
      this.fullColumns = [];
      return;
    }
    const goal = this.config.goal;
    if (goal.kind === "distance") {
      // The whole course is known in advance, so the columns never change.
      if (this.barColumns.length === 0) this.barColumns = this.profile.columns(0, goal.meters, 110);
      this.barMarker = goal.meters > 0 ? Math.min(1, this.distance / goal.meters) : 0;
      if (this.fullColumns.length === 0) this.fullColumns = this.profile.columns(0, goal.meters, 262);
      this.fullMarker = this.barMarker;
      this.fullWindow = [0, goal.meters];
    } else {
      this.barColumns = this.profile.columns(this.distance - 1000, this.distance + 4000, 110);
      this.barMarker = 0.2;
      this.fullColumns = this.profile.columns(this.distance - 2000, this.distance + 8000, 262);
      this.fullMarker = 0.2;
      this.fullWindow = [this.distance - 2000, this.distance + 8000];
    }
  }

  // MARK: Previews and snapshots

  /** Puts the engine into a fixed state without sensors (used for screenshots and tests). */
  applyPreview(p: { distance: number; movingTime: number; power: number; cadence: number; heartRate: number | null; gear: number; phase?: RidePhase }): void {
    this.distance = p.distance;
    this.movingTime = p.movingTime;
    this.power3s = p.power;
    this.cadence = p.cadence;
    this.heartRate = p.heartRate;
    this.phase = p.phase ?? "riding";
    this.gearbox = new VirtualGearbox(p.gear);
    this.gradePercent = this.usesCourse ? this.profile.grade(p.distance) : 0;
    this.speed = this.phase === "riding" ? BikePhysics.steadySpeed(p.power, this.gradePercent, this.settings.rider) : 0;
    const player = this.player;
    if (player) {
      const trace: PowerPoint[] = [];
      const rng = new SplitMix64(7);
      let last = (player.targetFraction(0) ?? 0.5) * this.ftp;
      for (let t = 0; t < p.movingTime; t += 5) {
        const target = (player.targetFraction(t) ?? 0.5) * this.ftp;
        last += (target - last) * 0.5 + (rng.unit() - 0.5) * 0.07 * target;
        trace.push({ time: t, watts: last });
      }
      this.powerTrace = trace;
    }
    const plan = this.config.test;
    const tracker = this.testTracker;
    if (plan && tracker) {
      // Feed the test as if the rider had held every target.
      for (let t = plan.effortStart; t < p.movingTime && !tracker.finished; t += 1) {
        const f = player?.targetFraction(t);
        const target = f != null ? rnd(f * this.ftp) : Math.trunc(plan.baseFTP * 1.02);
        tracker.add(t, target, p.cadence, target);
      }
    }
    this.updateWorkoutTarget();
    this.refreshColumns();
  }
}
