// State shared between the main process and the windows: settings, app state, ride snapshot.
import { Fmt, PowerZones, Theme, TargetCompliance, compliance, complianceLabel, rnd, riderParameters } from "./basics";
import { DeviceRole } from "./ble";
import { CoursePreset, GradeRange, ProfileColumn, coursePreset } from "./elevation";
import { DisplayMode, GoalKind, PowerPoint, ResistanceMode, RideEngine, RidePhase, SessionGoal, WorkoutMode, goalLabel, workoutModeTitle } from "./engine";
import { RideEntry } from "./ride";
import { CustomWorkout, FTPTestKind, FTPTestResult, Step, Workout, WorkoutStep, ftpTestKind, testCooldown } from "./workout";

// MARK: Settings

export interface Settings {
  riderWeight: number;
  bikeWeight: number;
  ftp: number;
  useIntervalsFTP: boolean;
  chainring: number;
  cog: number;
  measuredTrainerRatio: number;
  difficulty: number;
  resistanceMode: ResistanceMode;
  startGear: number;
  overlayOpacity: number;
  /** Third row in the bar with music and ride controls. */
  showControlRow: boolean;
  defaultDisplay: DisplayMode;
  coursePreset: CoursePreset;
  customMinGrade: number;
  customMaxGrade: number;
  goalKind: GoalKind;
  goalDistanceKm: number;
  goalDurationMin: number;
  workoutMode: WorkoutMode;
  intervalsAthleteId: string;
  autoUpload: boolean;
  ftpTestKind: FTPTestKind;
  /** Send a plausible test result to intervals.icu right away. */
  autoTransferFTP: boolean;
  /** Test result still to be sent to intervals.icu (0 = none), e.g. because no API key was set. */
  pendingFTPTransfer: number;
  /** role -> device address */
  assignedDevices: Partial<Record<DeviceRole, string>>;
  /** Learned Click v2 buttons: "pod:bit" -> "up" / "down". Empty = right half shifts up, left half down. */
  clickButtonMap: Record<string, string>;
  demoMode: boolean;
  /** Position and width of the floating bar. */
  overlayBounds: { x: number; y: number; width: number } | null;
}

export const defaultSettings: Settings = {
  riderWeight: 75,
  bikeWeight: 8,
  ftp: 250,
  useIntervalsFTP: true,
  chainring: 34,
  cog: 14,
  measuredTrainerRatio: 0,
  difficulty: 0.5,
  resistanceMode: "matchedSimulation",
  startGear: 12,
  overlayOpacity: 0.72,
  showControlRow: true,
  defaultDisplay: "bar",
  coursePreset: "hilly",
  customMinGrade: -4,
  customMaxGrade: 6,
  goalKind: "distance",
  goalDistanceKm: 30,
  goalDurationMin: 60,
  workoutMode: "ergOffset",
  intervalsAthleteId: "0",
  autoUpload: true,
  ftpTestKind: "ramp",
  autoTransferFTP: true,
  pendingFTPTransfer: 0,
  assignedDevices: {},
  clickButtonMap: {},
  demoMode: false,
  overlayBounds: null,
};

export function gradeRangeOf(s: Settings): GradeRange {
  return coursePreset(s.coursePreset).range ?? { min: Math.min(s.customMinGrade, s.customMaxGrade), max: Math.max(s.customMinGrade, s.customMaxGrade) };
}

export function riderOf(s: Settings) {
  return riderParameters(s.riderWeight, s.bikeWeight);
}

/** Gear ratio of the real drivetrain on the trainer (chainring / Zwift Cog), measured if available. */
export function trainerRatioOf(s: Settings): number {
  if (s.measuredTrainerRatio > 0.5) return s.measuredTrainerRatio;
  return Math.max(1, s.chainring) / Math.max(1, s.cog);
}

export function courseTitleOf(s: Settings): string {
  const range = gradeRangeOf(s);
  return `${coursePreset(s.coursePreset).title} · ${Fmt.signedGrade(range.min)} … +${Fmt.decimal(range.max, 0)} %`;
}

// MARK: App state

export type ConnectionState = "notAssigned" | "searching" | "connecting" | "connected" | "ready" | "failed";

export interface DeviceStatus {
  name: string | null;
  state: ConnectionState;
  /** Text for the "failed" state. */
  message: string | null;
  battery: number | null;
  detail: string | null;
}

export const emptyStatus = (state: ConnectionState = "notAssigned"): DeviceStatus => ({ name: null, state, message: null, battery: null, detail: null });

export const isUsable = (s: DeviceStatus | undefined) => s?.state === "ready" || s?.state === "connected";

export function stateLabel(s: DeviceStatus): string {
  switch (s.state) {
    case "notAssigned":
      return "Nicht gekoppelt";
    case "searching":
      return "Suche…";
    case "connecting":
      return "Verbinde…";
    case "connected":
      return "Verbunden";
    case "ready":
      return "Bereit";
    case "failed":
      return s.message ?? "Fehler";
  }
}

export interface DiscoveredDevice {
  id: string;
  name: string;
  rssi: number;
  roles: DeviceRole[];
}

export type AdapterState = "unknown" | "poweredOn" | "poweredOff" | "unavailable";

export type UploadState =
  | { kind: "idle" }
  | { kind: "waitingForKey" }
  | { kind: "uploading" }
  | { kind: "uploaded"; id: string }
  | { kind: "queued"; message: string }
  | { kind: "failed"; message: string };

export interface FTPChange {
  settingsId: number;
  /** "ftp" or "indoor_ftp" */
  field: string;
  previous: number | null;
  new: number | null;
}

export type FTPTransfer =
  | { kind: "idle" }
  | { kind: "waitingForKey" }
  | { kind: "sending" }
  | { kind: "transferred"; change: FTPChange }
  | { kind: "undone" }
  | { kind: "failed"; message: string }
  | { kind: "needsConfirmation"; reason: string };

export interface FTPOutcome {
  result: FTPTestResult;
  previousAppFTP: number;
  applied: boolean;
  transfer: FTPTransfer;
}

export interface MusicState {
  /** A player that can be controlled exists on this system. */
  installed: boolean;
  running: boolean;
  playing: boolean;
  track: { id: string; name: string; artist: string; artworkURL: string | null } | null;
}

export interface AppState {
  platform: string;
  version: string;
  settings: Settings;
  ble: {
    adapter: AdapterState;
    adapterMessage: string | null;
    isScanning: boolean;
    isDemo: boolean;
    discovered: DiscoveredDevice[];
    status: Record<DeviceRole, DeviceStatus>;
    visibleRoles: DeviceRole[];
    learningDirection: "up" | "down" | null;
    learnedSummary: string | null;
  };
  intervals: {
    configured: boolean;
    load: { kind: "idle" | "loading" | "loaded" | "failed"; message?: string };
    athleteName: string | null;
    athleteFTP: number | null;
    upcoming: Workout[];
    library: Workout[];
    effectiveFTP: number;
    zones: number[];
  };
  customWorkouts: CustomWorkout[];
  historyCount: number;
  pendingUploads: number;
  isRiding: boolean;
  displayMode: DisplayMode;
  overlayVisible: boolean;
  clickThrough: boolean;
  finished: { name: string; filename: string; uploadState: UploadState } | null;
  ftpOutcome: FTPOutcome | null;
  music: MusicState;
  ridesDirectory: string;
  /** Global shortcuts could be registered (not possible in every Wayland session). */
  shortcutsActive: boolean;
}

// MARK: Ride snapshot

export interface RideState {
  name: string;
  courseTitle: string;
  goal: SessionGoal;
  goalLabel: string;
  workoutMode: WorkoutMode;
  workoutModeTitle: string;
  usesCourse: boolean;
  isWorkout: boolean;
  isTest: boolean;
  testTitle: string | null;
  testKind: FTPTestKind | null;
  phase: RidePhase;
  manualPause: boolean;
  sensorless: boolean;
  speedFromCadence: boolean;
  movingTime: number;
  distance: number;
  watts: number;
  cadence: number;
  heartRate: number | null;
  gradePercent: number;
  gear: number;
  ergOffset: number;
  shiftCount: number;
  targetWatts: number | null;
  ftp: number;
  zones: number[];
  barColumns: ProfileColumn[];
  barMarker: number;
  fullColumns: ProfileColumn[];
  fullMarker: number;
  fullWindow: [number, number];
  powerTrace: PowerPoint[];
  canChangeGoal: boolean;
  canEndTestEffort: boolean;
  isInTestEffort: boolean;
  clickAdjustsErgOffset: boolean;
  testEstimate: number | null;
  hasTestResult: boolean;
  progress: number;
  altitude: number;
  ascent: number;
  nextKilometerGrade: number;
  remainingDistance: number | null;
  remainingTime: number | null;
  playerDuration: number;
  // Derived display values
  zoneIndex: number;
  isPaused: boolean;
  compliance: TargetCompliance | null;
  complianceText: string | null;
  wattColor: string;
  chipText: string;
  zoneLine: string;
  rpmText: string;
  kmhText: string;
  heartText: string;
  ergOffsetText: string;
  showsTarget: boolean;
  showsErgOffset: boolean;
  targetText: string;
  targetColor: string;
  gradeText: string;
  gradeColor: string;
  timeText: string;
  bottom: "profile" | "workout" | "paused";
  pauseHint: string;
  distanceValue: string;
  distanceSuffix: string;
  stepLeftText: string;
  workoutRightText: string;
  testInfo: string | null;
  testAverage: number | null;
  showsTestAverage: boolean;
  isOpenRamp: boolean;
  workoutSteps: WorkoutStep[];
  chartSteps: WorkoutStep[];
  chartDuration: number;
  chartTop: number;
  intervalLabel: string;
  stepProgress: number;
  stepColor: string;
  stepDescription: string;
  nextStep: { text: string; color: string } | null;
  footerLeft: string;
  footerRight: string;
  phaseText: string;
}

const dim = "rgba(255,255,255,0.4)";

/** Display values for the bar and the full screen view, derived from the engine. */
export function snapshotRide(engine: RideEngine, ftp: number, zones: PowerZones, shortcuts = "Strg+Alt+P"): RideState {
  const config = engine.config;
  const plan = config.test;
  const watts = engine.power3s;
  const zoneIndex = zones.index(watts, ftp);
  const isPaused = engine.phase === "paused" || engine.phase === "waiting";
  const comp = engine.targetWatts != null && engine.isWorkout ? compliance(watts, engine.targetWatts) : null;
  const color = isPaused ? dim : comp ? Theme.complianceColor(comp) : Theme.zoneColor(zoneIndex);
  const position = engine.workoutPosition;
  const player = engine.player;
  const workoutSteps = player?.workout.steps ?? [];
  const tracker = engine.testTracker;
  const testAverage = tracker?.average ?? null;
  const isOpenRamp = plan?.kind === "ramp" && engine.testResult == null;

  const stepName = (step: WorkoutStep): string => {
    if (step.startFraction == null) return "Freie Fahrt";
    if (step.kind === "ramp") return "Rampe";
    return PowerZones.zoneName(zones.indexForFraction(step.startFraction));
  };

  // "Stufe 7 · FTP ≈ 201 W", "Ø 241 W · FTP ≈ 229 W", "Neue FTP: 229 W" …
  let testInfo: string | null = null;
  if (plan) {
    if (engine.testResult) {
      testInfo = `Neue FTP: ${engine.testResult.ftp} W`;
    } else if (engine.movingTime < plan.effortStart) {
      const left = Fmt.clock(plan.effortStart - engine.movingTime, false);
      testInfo = plan.kind === "ramp" ? `Rampe startet in ${left}` : `20 Minuten starten in ${left}`;
    } else {
      const estimate = engine.testEstimate != null ? `FTP ≈ ${engine.testEstimate} W` : "FTP ≈ …";
      if (plan.kind === "ramp") testInfo = `Stufe ${Math.floor((engine.movingTime - plan.effortStart) / 60) + 1} · ${estimate}`;
      else testInfo = testAverage != null ? `Ø ${testAverage} W · ${estimate}` : estimate;
    }
  }

  let nextStepText = "";
  if (player && position) {
    const next = player.nextStep(position.index);
    if (!next) nextStepText = "danach Schluss";
    else if (next.startFraction != null) nextStepText = `danach ${rnd(next.startFraction * ftp)} W`;
    else nextStepText = "danach frei";
  }

  // Steps shown in the charts. A running ramp shows only the next few steps (up to about 130 % FTP).
  let chartSteps = workoutSteps;
  if (isOpenRamp) {
    const current = position?.index ?? 0;
    const shown: WorkoutStep[] = [];
    for (let i = 0; i < workoutSteps.length; i++) {
      const step = workoutSteps[i];
      if (Step.equal(step, testCooldown)) continue;
      if (!(i <= current + 4 || (step.startFraction ?? 0) <= 1.3)) break;
      shown.push(step);
    }
    chartSteps = [...shown, testCooldown];
  }
  const highest = Math.max(1, ...chartSteps.map((s) => Math.max(s.startFraction ?? 0, s.endFraction ?? 0)));
  const chartTop = Math.max(1.2, (chartSteps.length ? highest : 1) * 1.05);

  let distanceSuffix: string;
  if (config.goal.kind === "distance") distanceSuffix = `/ ${Fmt.km(config.goal.meters)} km`;
  else distanceSuffix = engine.remainingTime != null ? `km · noch ${Fmt.clock(engine.remainingTime, false)}` : "km";

  let pauseHint: string;
  if (engine.phase === "waiting") pauseHint = "Tritt an, um zu starten";
  else if (engine.manualPause || engine.sensorless) pauseHint = `Weiter mit ${shortcuts}`;
  else pauseHint = "Tritt an, um weiterzufahren";

  let intervalLabel = "ABSCHNITT";
  let stepProgress = 0;
  let stepColor = "rgba(255,255,255,0.5)";
  let stepDescription = "";
  let nextStep: RideState["nextStep"] = null;
  if (position && player) {
    const rep = player.repetition(position.index);
    if (engine.isTest && position.step.label) intervalLabel = `${position.step.label.toUpperCase()} · NOCH`;
    else if (rep) intervalLabel = `INTERVALL ${rep.current} / ${rep.total} · NOCH`;
    else intervalLabel = `ABSCHNITT ${position.index + 1} / ${workoutSteps.length} · NOCH`;
    stepProgress = position.step.duration > 0 ? position.timeInStep / position.step.duration : 0;
    const f = Step.fraction(position.step, position.timeInStep);
    if (f != null) stepColor = Theme.zoneColor(zones.indexForFraction(f));
    const duration = Fmt.clock(position.step.duration, false);
    const name = position.step.label ?? stepName(position.step);
    if (position.step.startFraction != null) {
      const a = position.step.startFraction;
      const b = position.step.endFraction ?? a;
      const pct = a === b ? `${rnd(a * 100)} %` : `${rnd(a * 100)}–${rnd(b * 100)} %`;
      stepDescription = `${name} · ${duration} bei ${pct} FTP`;
    } else {
      stepDescription = `${name} · ${duration}`;
    }
    const next = player.nextStep(position.index);
    if (next) {
      const text = `${next.label ?? stepName(next)} · ${Fmt.clock(next.duration, false)}`;
      nextStep =
        next.startFraction != null
          ? { text: `${text} · ${rnd(next.startFraction * ftp)} W`, color: Theme.zoneColor(zones.indexForFraction(next.startFraction)) }
          : { text, color: dim };
    }
  }

  let footerRight = "";
  if (isOpenRamp) footerRight = engine.isInTestEffort ? "bis du nicht mehr kannst" : "Rampe folgt";
  else if (engine.remainingDistance != null) footerRight = `noch ${Fmt.km(engine.remainingDistance)} km`;
  else if (engine.remainingTime != null) footerRight = `noch ${Fmt.clock(engine.remainingTime, false)}`;

  let phaseText: string;
  switch (engine.phase) {
    case "waiting":
      phaseText = "Bereit – tritt an, um zu starten";
      break;
    case "riding":
      if (engine.sensorless) phaseText = `Fahrt läuft ohne Trainer und Kadenz – Pause mit ${shortcuts} oder beiden Click-Tasten`;
      else if (engine.speedFromCadence) phaseText = "Fahrt läuft ohne Trainer – Tempo aus Trittfrequenz und Gang";
      else phaseText = "Fahrt läuft";
      break;
    case "paused":
      phaseText = engine.manualPause ? "Pausiert" : "Automatisch pausiert";
      break;
    default:
      phaseText = "Beendet";
  }

  const percent = ftp > 0 ? rnd((watts / ftp) * 100) : 0;
  return {
    name: config.name,
    courseTitle: config.courseTitle,
    goal: config.goal,
    goalLabel: goalLabel(config.goal),
    workoutMode: config.workoutMode,
    workoutModeTitle: workoutModeTitle(config.workoutMode),
    usesCourse: engine.usesCourse,
    isWorkout: engine.isWorkout,
    isTest: engine.isTest,
    testTitle: plan ? ftpTestKind(plan.kind).title : null,
    testKind: plan?.kind ?? null,
    phase: engine.phase,
    manualPause: engine.manualPause,
    sensorless: engine.sensorless,
    speedFromCadence: engine.speedFromCadence,
    movingTime: engine.movingTime,
    distance: engine.distance,
    watts,
    cadence: engine.cadence,
    heartRate: engine.heartRate,
    gradePercent: engine.gradePercent,
    gear: engine.gearbox.gear,
    ergOffset: engine.ergOffset,
    shiftCount: engine.shiftCount,
    targetWatts: engine.targetWatts,
    ftp,
    zones: zones.upperBounds,
    barColumns: engine.barColumns,
    barMarker: engine.barMarker,
    fullColumns: engine.fullColumns,
    fullMarker: engine.fullMarker,
    fullWindow: engine.fullWindow,
    powerTrace: engine.powerTrace,
    canChangeGoal: engine.canChangeGoal,
    canEndTestEffort: engine.canEndTestEffort,
    isInTestEffort: engine.isInTestEffort,
    clickAdjustsErgOffset: engine.clickAdjustsErgOffset,
    testEstimate: engine.testEstimate,
    hasTestResult: engine.testResult != null,
    progress: engine.progress,
    altitude: engine.altitude,
    ascent: engine.ascent,
    nextKilometerGrade: engine.nextKilometerGrade,
    remainingDistance: engine.remainingDistance,
    remainingTime: engine.remainingTime,
    playerDuration: player?.duration ?? 0,
    zoneIndex,
    isPaused,
    compliance: comp,
    complianceText: comp ? complianceLabel(comp) : null,
    wattColor: color,
    chipText: isPaused ? "—" : comp ? complianceLabel(comp) : PowerZones.shortName(zoneIndex),
    zoneLine: `${PowerZones.shortName(zoneIndex)} · ${PowerZones.zoneName(zoneIndex)} · ${percent} % FTP`,
    rpmText: String(engine.cadence),
    kmhText: Fmt.decimal(engine.speed * 3.6, 1),
    heartText: engine.heartRate != null ? String(engine.heartRate) : "–",
    ergOffsetText: engine.ergOffset >= 0 ? `+${engine.ergOffset}` : `−${Math.abs(engine.ergOffset)}`,
    // Slot 6 shows the target instead of the grade while ERG holds the power.
    showsTarget: engine.isErgActive && engine.targetWatts != null,
    showsErgOffset: engine.clickAdjustsErgOffset,
    targetText: engine.targetWatts != null ? String(engine.targetWatts) : "–",
    targetColor: engine.targetWatts != null ? Theme.zoneColor(zones.index(engine.targetWatts, ftp)) : "#fff",
    gradeText: Fmt.decimal(Math.abs(engine.gradePercent), 1),
    gradeColor: Theme.gradeColor(engine.gradePercent),
    timeText: Fmt.clock(engine.movingTime, !engine.isWorkout),
    bottom: isPaused ? "paused" : engine.isWorkout ? "workout" : "profile",
    pauseHint,
    distanceValue: Fmt.km(engine.distance),
    distanceSuffix,
    stepLeftText: position ? Fmt.clock(position.remainingInStep, false) : "0:00",
    workoutRightText: `übrig · ${testInfo ?? nextStepText}`,
    testInfo,
    testAverage,
    // 20-minute effort: slot 6 shows the running average instead of the (flat) grade.
    showsTestAverage: plan?.kind === "twenty" && engine.isInTestEffort,
    isOpenRamp,
    workoutSteps,
    chartSteps,
    chartDuration: chartSteps.reduce((s, x) => s + x.duration, 0),
    chartTop,
    intervalLabel,
    stepProgress,
    stepColor,
    stepDescription,
    nextStep,
    footerLeft: config.goal.kind === "distance" ? `${Fmt.km(engine.distance)} km` : Fmt.clock(engine.movingTime, false),
    footerRight,
    phaseText,
  };
}

export type { RideEntry };
