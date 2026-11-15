// Root state of the app: ride lifecycle, uploads, FTP test results. No Electron in here.
import path from "node:path";
import { Fmt, ShiftDirection } from "../core/basics";
import { coursePreset } from "../core/elevation";
import { DisplayMode, RideEngine, SessionConfig, SessionGoal, workoutModeTitle } from "../core/engine";
import { RideEntry, RideSummary, buildActivityFIT, computeSummary, makeEntry } from "../core/ride";
import { AppState, FTPOutcome, RideState, Settings, UploadState, courseTitleOf, gradeRangeOf, riderOf, snapshotRide, trainerRatioOf } from "../core/state";
import { Custom, CustomWorkout, FTPTestKind, FTPTestPlan, FTPTestResult, Workout, customIdPrefix, ftpTestKind, makeTestPlan, testBasisText } from "../core/workout";
import { BLEManager } from "./ble/manager";
import { BleTransport } from "./ble/bluez";
import { CustomWorkoutStore, IntervalsClient, MusicController, RideStore, SettingsStore, errorText } from "./services";

export interface RideUICoordinator {
  rideDidStart(): void;
  rideDidFinish(): void;
  displayModeChanged(): void;
  overlayStateChanged(): void;
}

/** A finished ride. It is already saved on disk; this tracks its upload. */
interface FinishedRide {
  summary: RideSummary;
  name: string;
  filename: string;
  pairedEventId: number | null;
  uploadState: UploadState;
}

export type StartRequest = { kind: "free"; seed: number } | { kind: "workout"; seed: number; workoutId: string } | { kind: "ftpTest"; seed: number };

export interface ModelOptions {
  dataDirectory: string;
  transport: BleTransport;
  apiKey: string;
  storeKey: (key: string) => void;
  /** Keep settings in memory only (tests, smoke test). */
  ephemeralSettings?: boolean;
  http?: typeof fetch;
  platform?: string;
  version?: string;
  /** How the pause shortcut is written in hints. */
  shortcutLabel?: string;
}

export class AppModel {
  readonly settings: SettingsStore;
  readonly ble: BLEManager;
  readonly intervals: IntervalsClient;
  readonly music = new MusicController();
  readonly rides: RideStore;
  /** Workouts built in the app. */
  readonly customWorkouts: CustomWorkoutStore;

  engine: RideEngine | null = null;
  finished: FinishedRide | null = null;
  displayMode: DisplayMode;
  overlayVisible = true;
  clickThrough = false;
  /** All saved rides, newest first. */
  history: RideEntry[] = [];
  /** Result of the last FTP test (shown during the cooldown and in the summary). */
  ftpOutcome: FTPOutcome | null = null;
  shortcutsActive = false;

  coordinator: RideUICoordinator | null = null;
  /** Called when the light app state changed. */
  onStateChange: () => void = () => undefined;
  /** Called when the list of saved rides changed. */
  onHistoryChange: () => void = () => undefined;

  constructor(private readonly options: ModelOptions) {
    const dir = options.dataDirectory;
    this.settings = new SettingsStore(options.ephemeralSettings ? null : path.join(dir, "settings.json"));
    this.customWorkouts = new CustomWorkoutStore(path.join(dir, "Workouts.json"));
    this.rides = new RideStore(path.join(dir, "Rides"));
    this.ble = new BLEManager(this.settings, options.transport);
    this.intervals = new IntervalsClient(() => this.settings.get(), options.apiKey, options.storeKey, options.http);
    this.displayMode = this.settings.get().defaultDisplay;
    const changed = () => this.onStateChange();
    this.settings.onChange = changed;
    this.ble.onChange = changed;
    this.intervals.onChange = changed;
    this.music.onChange = changed;
  }

  get s(): Settings {
    return this.settings.get();
  }

  bootstrap(): void {
    this.ble.onShift = (direction) => this.shift(direction);
    this.ble.onBothButtons = () => this.togglePause();
    this.ble.onTrainerReady = () => this.engine?.resendResistance();
    this.ble.start();
    this.rides.adoptLooseFiles(this.intervals.effectiveFTP, this.intervals.zones);
    this.rides.completeDetails(this.intervals.effectiveFTP, this.intervals.zones);
    this.reloadHistory();
    void this.intervals.refreshAll().then(() => this.syncPending());
  }

  reloadHistory(): void {
    this.history = this.rides.entries();
    this.onHistoryChange();
    this.onStateChange();
  }

  get pendingUploads(): number {
    return this.history.filter((e) => !e.uploadedActivityId).length;
  }

  /** Called when the app comes to the front: refresh workouts and upload waiting rides. */
  appDidBecomeActive(): void {
    void this.intervals.refreshIfStale().then(() => this.syncPending());
  }

  get isRiding(): boolean {
    return this.engine != null && this.engine.phase !== "finished";
  }

  // MARK: Snapshots

  state(): AppState {
    const i = this.intervals;
    return {
      platform: this.options.platform ?? process.platform,
      version: this.options.version ?? "",
      settings: this.s,
      ble: this.ble.snapshot(),
      intervals: {
        configured: i.isConfigured,
        load: i.load,
        athleteName: i.athlete?.name ?? null,
        athleteFTP: i.athlete?.ftp ?? null,
        upcoming: i.upcoming,
        library: i.library,
        effectiveFTP: i.effectiveFTP,
        zones: i.zones.upperBounds,
      },
      customWorkouts: this.customWorkouts.workouts,
      historyCount: this.history.length,
      pendingUploads: this.pendingUploads,
      isRiding: this.isRiding,
      displayMode: this.displayMode,
      overlayVisible: this.overlayVisible,
      clickThrough: this.clickThrough,
      finished: this.finished ? { name: this.finished.name, filename: this.finished.filename, uploadState: this.finished.uploadState } : null,
      ftpOutcome: this.ftpOutcome,
      music: this.music.state,
      ridesDirectory: this.rides.directory,
      shortcutsActive: this.shortcutsActive,
    };
  }

  rideState(): RideState | null {
    if (!this.engine || this.engine.phase === "finished") return null;
    return snapshotRide(this.engine, this.intervals.effectiveFTP, this.intervals.zones, this.options.shortcutLabel);
  }

  // MARK: Session

  /** Builds the FTP test for the current FTP. */
  makeTestPlan(kind: FTPTestKind): FTPTestPlan {
    const known = this.s.useIntervalsFTP && this.intervals.athlete?.ftp != null;
    return makeTestPlan(kind, this.intervals.effectiveFTP, known);
  }

  private findWorkout(id: string): Workout | null {
    const custom = this.customWorkouts.workout(id);
    if (custom) return Custom.asWorkout(custom);
    return [...this.intervals.upcoming, ...this.intervals.library].find((w) => w.id === id) ?? null;
  }

  /** Starts a ride from the choices made in the setup view. */
  start(request: StartRequest): boolean {
    const s = this.s;
    const range = gradeRangeOf(s);
    const courseTitle = courseTitleOf(s);
    const preset = coursePreset(s.coursePreset).title;
    if (request.kind === "ftpTest") {
      const plan = this.makeTestPlan(s.ftpTestKind);
      this.startRide({
        name: plan.workout.name,
        courseTitle: ftpTestKind(plan.kind).title,
        gradeRange: { min: 0, max: 0 },
        seed: request.seed,
        goal: { kind: "workout" },
        workout: plan.workout,
        workoutMode: "ergGears",
        presetTitle: "FTP-Test",
        test: plan,
      });
      return true;
    }
    if (request.kind === "workout") {
      const workout = this.findWorkout(request.workoutId);
      if (!workout) return false;
      this.startRide({
        name: workout.name,
        courseTitle,
        gradeRange: range,
        seed: request.seed,
        goal: { kind: "workout" },
        workout,
        workoutMode: s.workoutMode,
        presetTitle: "",
        test: null,
      });
      return true;
    }
    const goal: SessionGoal = s.goalKind === "distance" ? { kind: "distance", meters: s.goalDistanceKm * 1000 } : { kind: "duration", seconds: s.goalDurationMin * 60 };
    const goalText = s.goalKind === "distance" ? `${Math.trunc(s.goalDistanceKm)} km` : `${Math.trunc(s.goalDurationMin)} min`;
    this.startRide({
      name: `Bike App – ${preset} ${goalText}`,
      courseTitle,
      gradeRange: range,
      seed: request.seed,
      goal,
      workout: null,
      workoutMode: s.workoutMode,
      presetTitle: preset,
      test: null,
    });
    return true;
  }

  startRide(config: SessionConfig, autoTick = true): RideEngine {
    this.engine?.finish();
    this.finished = null;
    this.ftpOutcome = null;
    const settings = this.settings;
    const engine = new RideEngine(
      config,
      {
        get rider() {
          return riderOf(settings.get());
        },
        get difficulty() {
          return settings.get().difficulty;
        },
        get resistanceMode() {
          return settings.get().resistanceMode;
        },
        get startGear() {
          return settings.get().startGear;
        },
        get trainerRatio() {
          return trainerRatioOf(settings.get());
        },
        get measuredTrainerRatio() {
          return settings.get().measuredTrainerRatio;
        },
        setMeasuredTrainerRatio: (ratio) => settings.set({ measuredTrainerRatio: ratio }),
      },
      this.ble,
      () => this.intervals.effectiveFTP,
    );
    engine.onFinish = (e) => this.rideFinished(e);
    engine.onTestResult = (result) => this.handleTestResult(result);
    this.engine = engine;
    this.displayMode = this.s.defaultDisplay;
    this.overlayVisible = true;
    engine.start(autoTick);
    if (this.s.showControlRow) this.music.start();
    this.coordinator?.rideDidStart();
    this.onStateChange();
    return engine;
  }

  stopRide(): void {
    this.engine?.finish();
  }

  discardRide(): void {
    this.engine = null;
    this.finished = null;
    this.onStateChange();
  }

  togglePause(): void {
    // During the ramp both Click buttons (or the shortcut) mean "I'm done", pausing would spoil the test.
    if (this.engine?.canEndTestEffort) {
      this.engine.endTestEffort();
      return;
    }
    this.engine?.togglePause();
  }

  endTestEffort(): void {
    this.engine?.endTestEffort();
  }

  shift(direction: ShiftDirection): void {
    this.engine?.shift(direction);
  }

  adjustGoal(steps: number): void {
    this.engine?.adjustGoal(steps);
    this.onStateChange();
  }

  setGoal(goal: SessionGoal): void {
    this.engine?.setGoal(goal);
    this.onStateChange();
  }

  // MARK: FTP test result

  private handleTestResult(result: FTPTestResult): void {
    const outcome: FTPOutcome = { result, previousAppFTP: this.s.ftp, applied: false, transfer: { kind: "idle" } };
    this.ftpOutcome = outcome;
    if (!result.plausible) {
      outcome.transfer = { kind: "needsConfirmation", reason: result.reason ?? "Das Ergebnis ist unsicher." };
      this.onStateChange();
      return;
    }
    this.applyFTP(this.s.autoTransferFTP);
  }

  /** Takes the test result as the new FTP in the app and optionally sends it to intervals.icu. */
  applyFTP(transfer: boolean): void {
    const outcome = this.ftpOutcome;
    if (!outcome) return;
    this.settings.set({ ftp: outcome.result.ftp });
    outcome.applied = true;
    if (transfer) this.transferFTP();
    else outcome.transfer = { kind: "idle" };
    this.onStateChange();
  }

  transferFTP(): void {
    const outcome = this.ftpOutcome;
    if (!outcome) return;
    const ftp = outcome.result.ftp;
    if (!this.intervals.isConfigured) {
      this.settings.set({ pendingFTPTransfer: ftp });
      outcome.transfer = { kind: "waitingForKey" };
      this.onStateChange();
      return;
    }
    outcome.transfer = { kind: "sending" };
    this.onStateChange();
    this.intervals
      .updateFTP(ftp)
      .then((change) => {
        this.settings.set({ pendingFTPTransfer: 0 });
        outcome.transfer = { kind: "transferred", change };
      })
      .catch((error) => {
        this.settings.set({ pendingFTPTransfer: ftp });
        outcome.transfer = { kind: "failed", message: errorText(error) };
      })
      .finally(() => this.onStateChange());
  }

  /** Puts back the FTP from before the test (app and intervals.icu). */
  undoFTP(): void {
    const outcome = this.ftpOutcome;
    if (!outcome) return;
    this.settings.set({ ftp: outcome.previousAppFTP });
    outcome.applied = false;
    if (this.s.pendingFTPTransfer === outcome.result.ftp) this.settings.set({ pendingFTPTransfer: 0 });
    if (outcome.transfer.kind !== "transferred") {
      outcome.transfer = { kind: "undone" };
      this.onStateChange();
      return;
    }
    const change = outcome.transfer.change;
    outcome.transfer = { kind: "sending" };
    this.onStateChange();
    this.intervals
      .restoreFTP(change)
      .then(() => {
        outcome.transfer = { kind: "undone" };
      })
      .catch((error) => {
        outcome.transfer = { kind: "failed", message: `Rückgängig fehlgeschlagen: ${errorText(error)}` };
      })
      .finally(() => this.onStateChange());
  }

  /** Sends a test result that waited for the API key. */
  private async transferPendingFTP(): Promise<void> {
    const ftp = this.s.pendingFTPTransfer;
    if (!(ftp > 0) || !this.intervals.isConfigured) return;
    const outcome = this.ftpOutcome?.result.ftp === ftp ? this.ftpOutcome : null;
    try {
      const change = await this.intervals.updateFTP(ftp);
      this.settings.set({ pendingFTPTransfer: 0 });
      if (outcome) outcome.transfer = { kind: "transferred", change };
    } catch (error) {
      if (outcome) outcome.transfer = { kind: "failed", message: errorText(error) };
    }
  }

  // MARK: After the ride

  private activityName(engine: RideEngine, summary: RideSummary): string {
    const plan = engine.config.test;
    if (plan) {
      const short = ftpTestKind(plan.kind).shortTitle;
      return engine.testResult ? `Bike App – FTP-Test (${short}) · FTP ${engine.testResult.ftp} W` : `Bike App – FTP-Test (${short})`;
    }
    if (engine.config.workout) return engine.config.name;
    const preset = engine.config.presetTitle === "" ? "Freie Fahrt" : engine.config.presetTitle;
    return `Bike App – ${preset} · ${Fmt.km(summary.distance)} km`;
  }

  private rideFinished(engine: RideEngine): void {
    const samples = engine.recorder.samples;
    this.coordinator?.rideDidFinish();
    this.music.stop();
    if (samples.length === 0) {
      this.engine = null;
      this.onStateChange();
      return;
    }
    const end = engine.endDate ?? Date.now();
    const summary = computeSummary(samples, engine.startDate, end);
    const fit = buildActivityFIT(samples, engine.recorder.laps, summary);
    const d = new Date(engine.startDate);
    const p = (n: number) => String(n).padStart(2, "0");
    const filename = `BikeApp-${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}-${p(d.getHours())}${p(d.getMinutes())}${p(d.getSeconds())}.fit`;
    const name = this.activityName(engine, summary);
    const result = engine.testResult;
    const description = result ? `FTP-Test mit Bike App: ${testBasisText(result)} = FTP ${result.ftp} W` : "Gefahren mit Bike App";
    const ride: FinishedRide = { summary, name, filename, pairedEventId: engine.config.workout?.eventId ?? null, uploadState: { kind: "idle" } };

    // Save first, so the ride survives missing key, missing network or quitting the app.
    let subtitle: string;
    const plan = engine.config.test;
    const workout = engine.config.workout;
    if (plan) {
      subtitle = `FTP-Test · ${ftpTestKind(plan.kind).title}${result ? ` · Ergebnis ${result.ftp} W` : ""}`;
    } else if (workout) {
      const source = workout.id.startsWith(customIdPrefix) ? "Eigenes Workout" : "intervals.icu-Workout";
      subtitle = `${source} · ${workoutModeTitle(engine.config.workoutMode)}`;
    } else {
      subtitle = engine.config.courseTitle;
    }
    const entry = makeEntry({
      id: filename,
      name,
      subtitle,
      description,
      pairedEventId: ride.pairedEventId,
      samples,
      summary,
      ftp: plan?.baseFTP ?? this.intervals.effectiveFTP,
      zones: this.intervals.zones,
    });
    entry.ftpTestResult = result?.ftp ?? null;
    this.rides.save(fit, entry);
    this.finished = ride;
    this.reloadHistory();

    if (!this.intervals.isConfigured) ride.uploadState = { kind: "waitingForKey" };
    else if (this.s.autoUpload) this.uploadFinished();
    this.onStateChange();
  }

  uploadFinished(): void {
    const ride = this.finished;
    if (!ride) return;
    if (!this.intervals.isConfigured) {
      ride.uploadState = { kind: "waitingForKey" };
      this.onStateChange();
      return;
    }
    ride.uploadState = { kind: "uploading" };
    this.onStateChange();
    this.rides
      .upload(ride.filename, this.intervals)
      .then((id) => {
        ride.uploadState = { kind: "uploaded", id };
      })
      .catch((error) => {
        ride.uploadState = { kind: "queued", message: errorText(error) };
      })
      .finally(() => this.reloadHistory());
  }

  /** Uploads one ride from the history. */
  async uploadStored(id: string): Promise<void> {
    if (!this.intervals.isConfigured) return;
    await this.rides.upload(id, this.intervals).catch(() => undefined);
    this.reloadHistory();
  }

  /** Deletes a ride from this computer (intervals.icu keeps its copy). */
  deleteRide(id: string): void {
    this.rides.delete(id);
    this.reloadHistory();
  }

  /** Uploads every saved ride that is not on intervals.icu yet. */
  async syncPending(): Promise<void> {
    if (!this.intervals.isConfigured) {
      this.reloadHistory();
      return;
    }
    await this.rides.uploadPending(this.intervals);
    await this.transferPendingFTP();
    // Keep the summary on screen in sync.
    const ride = this.finished;
    const entry = ride ? this.rides.entry(ride.filename) : null;
    if (ride && entry) {
      if (entry.uploadedActivityId) ride.uploadState = { kind: "uploaded", id: entry.uploadedActivityId === "ok" ? "" : entry.uploadedActivityId };
      else if (entry.lastError) ride.uploadState = { kind: "queued", message: entry.lastError };
    }
    this.reloadHistory();
  }

  /** Saves the API key, then loads workouts and uploads waiting rides. Returns a status line. */
  async saveAPIKey(key: string): Promise<string | null> {
    this.intervals.setAPIKey(key === "" ? this.intervals.apiKey : key);
    if (!this.intervals.isConfigured) return null;
    await this.intervals.refreshAll();
    await this.syncPending();
    const load = this.intervals.load;
    if (load.kind === "loaded") {
      const name = this.intervals.athlete?.name ?? "Konto";
      const waiting = this.pendingUploads;
      return waiting > 0 ? `Verbunden: ${name} · ${waiting} Fahrt(en) noch offen` : `Verbunden: ${name}`;
    }
    return load.kind === "failed" ? load.message ?? "Fehler" : null;
  }

  /** Adds FIT files to the history. Returns the number of files that could not be read. */
  async importFITs(files: string[]): Promise<number> {
    let failed = 0;
    for (const file of files) {
      try {
        this.rides.importFIT(file, this.intervals.effectiveFTP, this.intervals.zones);
      } catch {
        failed += 1;
      }
    }
    this.reloadHistory();
    await this.syncPending();
    return failed;
  }

  // MARK: Custom workouts

  saveWorkout(workout: CustomWorkout): string {
    const saved = this.customWorkouts.save({ ...workout, name: workout.name.trim() });
    this.onStateChange();
    return Custom.workoutId(saved);
  }

  deleteWorkout(id: string): void {
    this.customWorkouts.delete(id);
    this.onStateChange();
  }

  duplicateWorkout(id: string): string | null {
    const copy = this.customWorkouts.duplicate(id);
    this.onStateChange();
    return copy ? Custom.workoutId(copy) : null;
  }

  // MARK: Display

  setDisplayMode(mode: DisplayMode): void {
    if (mode === this.displayMode) return;
    this.displayMode = mode;
    this.coordinator?.displayModeChanged();
    this.onStateChange();
  }

  toggleDisplayMode(): void {
    this.setDisplayMode(this.displayMode === "bar" ? "fullscreen" : "bar");
  }

  toggleOverlay(): void {
    this.overlayVisible = !this.overlayVisible;
    this.coordinator?.overlayStateChanged();
    this.onStateChange();
  }

  toggleClickThrough(): void {
    this.clickThrough = !this.clickThrough;
    this.coordinator?.overlayStateChanged();
    this.onStateChange();
  }
}
