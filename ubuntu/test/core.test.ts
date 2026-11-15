import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { describe, expect, it } from "vitest";
import { BikePhysics, Fmt, PowerZones, VirtualGearbox, compliance, riderParameters } from "../src/core/basics";
import {
  ButtonMapTracker,
  ClickButtonInterpreter,
  ClickInputRouter,
  ClickKey,
  CrankCadenceCalculator,
  DeviceClassifier,
  FTMSCommand,
  BLEUUID,
  ZwiftClickProtocol,
  parseFTMSFeatures,
  parseHeartRate,
  parseIndoorBikeData,
  parsePowerRange,
} from "../src/core/ble";
import { ElevationProfile, SplitMix64 } from "../src/core/elevation";
import { RideEngine, SessionConfig, ergVirtualCommand, matchedSimulationCommand } from "../src/core/engine";
import { buildActivityFIT, computeSummary, entryFromFIT, fitCrc, normalizedPower, rideFromFIT, RideSample } from "../src/core/ride";
import { LiveSensors } from "../src/core/ble";
import { snapshotRide } from "../src/core/state";
import { Custom, FTPTestTracker, IntervalsParser, WorkoutPlayer, makeTestPlan, parseAthlete, parseDuration, rideSettings, truncatedTestWorkout } from "../src/core/workout";

describe("Formatierung", () => {
  it("formatiert wie die Mac-App", () => {
    expect(Fmt.decimal(39.46, 1)).toBe("39,5");
    expect(Fmt.clock(2530, true)).toBe("0:42:10");
    expect(Fmt.clock(1966, false)).toBe("32:46");
    expect(Fmt.clock(3725, false)).toBe("1:02:05");
    expect(Fmt.signedGrade(-3.2)).toBe("−3,2");
    expect(Fmt.km(12_400)).toBe("12,4");
  });
});

describe("Physik und Gänge", () => {
  const rider = riderParameters();
  it("findet die Geschwindigkeit, die eine Leistung hält", () => {
    const v = BikePhysics.steadySpeed(250, 0, rider);
    expect(v * 3.6).toBeGreaterThan(35);
    expect(v * 3.6).toBeLessThan(40);
    expect(BikePhysics.powerRequired(v, 0, rider)).toBeCloseTo(250, 0);
  });
  it("wird bergauf langsamer", () => {
    expect(BikePhysics.steadySpeed(250, 8, rider)).toBeLessThan(BikePhysics.steadySpeed(250, 0, rider) / 2);
  });
  it("beschleunigt bis zur Dauergeschwindigkeit", () => {
    let v = 0;
    for (let i = 0; i < 400; i++) v = BikePhysics.advance(v, 200, 0, 0.25, rider);
    expect(v).toBeCloseTo(BikePhysics.steadySpeed(200, 0, rider), 1);
  });
  it("hat 24 Gänge und bleibt an den Enden stehen", () => {
    const box = new VirtualGearbox(24);
    expect(box.shift("up")).toBe(false);
    expect(new VirtualGearbox(1).shift("down")).toBe(false);
    expect(new VirtualGearbox(99).gear).toBe(24);
  });
  it("Zonen und Zielbereich", () => {
    const zones = new PowerZones();
    expect(zones.index(245, 250)).toBe(3);
    expect(zones.index(100, 250)).toBe(0);
    expect(zones.index(400, 250)).toBe(5);
    expect(compliance(228, 230)).toBe("inTarget");
    expect(compliance(200, 230)).toBe("tooLow");
  });
});

describe("Widerstand", () => {
  const base = { gradePercent: 4, difficulty: 0.5, virtualRatio: 2.43, trainerRatio: 34 / 14, cadence: 90, rider: riderParameters() };
  it("gibt bei gleichem Gang die halbe Steigung weiter", () => {
    const c = matchedSimulationCommand(base);
    expect(c.kind).toBe("sim");
    if (c.kind === "sim") expect(c.gradePercent).toBeCloseTo(2, 0);
  });
  it("ein schwererer Gang wird härter", () => {
    const easy = matchedSimulationCommand({ ...base, virtualRatio: 1.5 });
    const hard = matchedSimulationCommand({ ...base, virtualRatio: 4.5 });
    if (easy.kind === "sim" && hard.kind === "sim") expect(hard.windResistance).toBeGreaterThan(easy.windResistance);
  });
  it("ERG aus Gang und Kadenz", () => {
    const c = ergVirtualCommand({ ...base, gradePercent: 0 });
    expect(c.kind).toBe("erg");
    if (c.kind === "erg") expect(c.watts).toBeGreaterThan(100);
  });
});

describe("Höhenprofil", () => {
  it("SplitMix64 liefert dieselben Zahlen wie in Swift", () => {
    const rng = new SplitMix64(42);
    expect(rng.unit()).toBeCloseTo(0.7415648787718233, 15);
    expect(rng.unit()).toBeCloseTo(0.1599103928769201, 15);
    expect(rng.unit()).toBeCloseTo(0.27860113025513866, 15);
  });
  it("ist für denselben Seed gleich und bleibt im Bereich", () => {
    const a = new ElevationProfile({ min: -5, max: 7 }, 502);
    const b = new ElevationProfile({ min: -5, max: 7 }, 502);
    a.ensure(30_000);
    b.ensure(30_000);
    expect(a.grades).toEqual(b.grades);
    expect(Math.min(...a.grades)).toBeGreaterThanOrEqual(-5);
    expect(Math.max(...a.grades)).toBeLessThanOrEqual(7);
    expect(a.ascent(30_000)).toBeGreaterThan(50);
  });
  it("liefert Säulen zwischen 0 und 1", () => {
    const cols = new ElevationProfile({ min: 0, max: 2 }, 1).columns(0, 5000, 110);
    expect(cols).toHaveLength(110);
    for (const c of cols) {
      expect(c.norm).toBeGreaterThanOrEqual(0);
      expect(c.norm).toBeLessThanOrEqual(1);
    }
  });
});

describe("Bluetooth-Protokolle", () => {
  it("liest FTMS Indoor Bike Data", () => {
    // flags: cadence + power present, speed 3600 (36 km/h), cadence 180 (90 rpm), power 250
    const d = parseIndoorBikeData([0x44, 0x00, 0x10, 0x0e, 0xb4, 0x00, 0xfa, 0x00]);
    expect(d).toEqual({ speedKmh: 36, cadence: 90, power: 250 });
  });
  it("kodiert Trainerbefehle", () => {
    expect(FTMSCommand.encode({ kind: "erg", watts: 250 })).toEqual([0x05, 0xfa, 0x00]);
    expect(FTMSCommand.encode({ kind: "sim", gradePercent: -2.5, crr: 0.004, windResistance: 0.38 })).toEqual([0x11, 0, 0, 0x06, 0xff, 40, 38]);
    expect(FTMSCommand.parseResponse([0x80, 0x00, 0x01])).toEqual({ opcode: 0, result: 1 });
  });
  it("liest Fähigkeiten, Leistungsbereich, Puls", () => {
    expect(parseFTMSFeatures([0, 0, 0, 0, 0x08, 0x20, 0, 0])).toEqual({ supportsPowerTarget: true, supportsSimulation: true });
    expect(parsePowerRange([0, 0, 0xd0, 0x07, 1, 0])).toEqual({ minimum: 0, maximum: 2000 });
    expect(parseHeartRate([0x00, 142])).toBe(142);
    expect(parseHeartRate([0x01, 0x2c, 0x01])).toBe(300);
  });
  it("berechnet die Kadenz aus Kurbelumdrehungen", () => {
    const c = new CrankCadenceCalculator();
    c.update([0x02, 10, 0, 0, 0], 0);
    // 1 revolution in 1024/1024 s = 60 rpm... 1.5 revolutions → use 3 revs in 2 s = 90 rpm
    expect(c.update([0x02, 13, 0, 0x00, 0x08], 2)).toBeCloseTo(90, 5);
  });
  it("versteht den Click v1 und v2", () => {
    expect(ZwiftClickProtocol.decode([...ZwiftClickProtocol.rideOn, 1, 2])).toEqual({ kind: "handshake", encrypted: false });
    expect(ZwiftClickProtocol.decode([0x37, 0x08, 0x00, 0x10, 0x01])).toEqual({ kind: "buttons", buttons: { plus: true, minus: false } });
    expect(ZwiftClickProtocol.decode([0x23, 0x08, 0xff, 0xff, 0x03])).toEqual({ kind: "buttonMap", map: 0xffff });
    expect(ZwiftClickProtocol.decode([0xff, 0x04])).toEqual({ kind: "locked" });
    const tracker = new ButtonMapTracker();
    expect(tracker.pressed(0xffff)).toEqual([]);
    expect(tracker.pressed(0xfffe)).toEqual([1]);
  });
  it("beide Tasten pausieren und nehmen den ersten Schaltvorgang zurück", () => {
    const i = new ClickButtonInterpreter();
    expect(i.process({ plus: true, minus: false }).map((a) => a.kind)).toEqual(["shift", "startRepeat"]);
    expect(i.process({ plus: true, minus: true })).toEqual([{ kind: "stopRepeat" }, { kind: "shift", direction: "down" }, { kind: "bothPressed" }]);
    expect(i.process({ plus: false, minus: false })).toEqual([]);
  });
  it("Click v2: rechte Hälfte schwerer, linke leichter, beide zusammen = Pause", () => {
    const events: string[] = [];
    const router = new ClickInputRouter(() => ({}));
    router.onShift = (d) => events.push(d);
    router.onBothButtons = () => events.push("both");
    router.update("R", new Set([ClickKey.make("right", 1)]));
    router.update("R", new Set());
    router.update("L", new Set([ClickKey.make("left", 4)]));
    router.update("R", new Set([ClickKey.make("right", 1)]));
    expect(events).toEqual(["up", "down", "up", "both"]);
  });
  it("erkennt die Geräte", () => {
    expect(DeviceClassifier.roles("KICKR CORE 2 1234", [], {})).toEqual(["trainer"]);
    expect(DeviceClassifier.roles("Zwift Click", [], { 0x094a: [0x0b, 1, 2] })).toEqual(["clickLeft"]);
    expect(DeviceClassifier.roles("HRM", [BLEUUID.heartRateService], {})).toEqual(["heartRate"]);
    expect(DeviceClassifier.trainerModel("KICKR CORE 2 ABCD")).toBe("Kickr Core 2");
  });
});

describe("Workouts", () => {
  it("liest intervals.icu-Workouts mit Wiederholungen", () => {
    const events = [
      {
        id: 77,
        category: "WORKOUT",
        type: "Ride",
        name: "Sweet Spot",
        start_date_local: "2026-11-16T00:00:00",
        workout_doc: {
          ftp: 250,
          steps: [
            { duration: 600, power: { start: 45, end: 70, units: "%ftp" }, ramp: true },
            { reps: 3, steps: [{ duration: 600, power: { value: 90, units: "%ftp" } }, { duration: 300, power: { value: 125, units: "w" } }] },
            { duration: 300, freeride: true },
          ],
        },
      },
      { id: 78, type: "Run", workout_doc: { steps: [{ duration: 60 }] } },
    ];
    const workouts = IntervalsParser.parseEvents(events, 250);
    expect(workouts).toHaveLength(1);
    const w = workouts[0];
    expect(w.eventId).toBe(77);
    expect(w.steps).toHaveLength(8);
    expect(w.steps[0].kind).toBe("ramp");
    expect(w.steps[2].startFraction).toBeCloseTo(0.5);
    expect(w.steps[7].kind).toBe("free");
  });
  it("Workout-Player findet die Position", () => {
    const w = Custom.asWorkout(Custom.templates()[1]);
    const player = new WorkoutPlayer(w);
    expect(player.duration).toBe(65 * 60);
    expect(player.position(605)?.index).toBe(1);
    expect(player.repetition(1)).toEqual({ current: 1, total: 3 });
    expect(player.position(99_999)).toBeNull();
  });
  it("Editor: intervals.icu-Text, TSS und Rückumwandlung", () => {
    const w = Custom.templates()[1];
    expect(Custom.intervalsText(w)).toBe("- Aufwärmen 10m ramp 45-70%\n\n3x\n- Sweet Spot 10m 90%\n- Erholung 5m 55%\n\n- Ausfahren 10m ramp 65-45%");
    expect(Custom.stressScore(w)).toBeGreaterThan(50);
    const back = Custom.from(Custom.asWorkout(w));
    expect(back.blocks.map((b) => b.kind)).toEqual(["ramp", "repeats", "ramp"]);
    expect(back.blocks[1].reps).toBe(3);
  });
  it("liest Dauern", () => {
    expect(parseDuration("4:30")).toBe(270);
    expect(parseDuration("10")).toBe(600);
    expect(parseDuration("1:02:00")).toBe(3720);
    expect(parseDuration("x")).toBeNull();
  });
  it("Athletendaten", () => {
    const json = { name: "M", icu_weight: 74, sportSettings: [{ id: 3015373, types: ["Ride", "VirtualRide"], ftp: 240, indoor_ftp: null, power_zones: [55, 75, 90, 105, 120, 150] }] };
    expect(parseAthlete(json)).toEqual({ name: "M", ftp: 240, weight: 74, zones: [55, 75, 90, 105, 120] });
    expect(rideSettings(json)).toEqual({ id: 3015373, ftp: 240, indoorFTP: null });
  });
});

describe("FTP-Test", () => {
  it("Rampe: 75 % der besten Minute", () => {
    const plan = makeTestPlan("ramp", 250, true);
    const tracker = new FTPTestTracker(plan);
    let t = plan.effortStart;
    for (; t < plan.effortStart + 600; t++) tracker.add(t, 300, 90, 300);
    tracker.endManually();
    expect(tracker.result?.ftp).toBe(225);
    expect(tracker.result?.plausible).toBe(true);
  });
  it("Rampe endet bei zu niedriger Kadenz", () => {
    const plan = makeTestPlan("ramp", 250, false);
    const tracker = new FTPTestTracker(plan);
    let ended = false;
    for (let t = plan.effortStart; t < plan.effortStart + 400 && !ended; t++) ended = tracker.add(t, 300, t > plan.effortStart + 300 ? 30 : 90, 300);
    expect(ended).toBe(true);
  });
  it("20 Minuten: zu kurz ist nicht plausibel", () => {
    const plan = makeTestPlan("twenty", 250, false);
    const tracker = new FTPTestTracker(plan);
    for (let t = plan.effortStart; t < plan.effortStart + 300; t++) tracker.add(t, 260, 90, null);
    tracker.endManually();
    expect(tracker.result?.plausible).toBe(false);
  });
  it("schneidet die Rampe ab und hängt das Ausfahren an", () => {
    const plan = makeTestPlan("ramp", 250, false);
    const cut = truncatedTestWorkout(plan.workout, plan.effortStart + 90);
    expect(cut.steps[cut.steps.length - 1].label).toBe("Ausfahren");
    expect(cut.steps.reduce((s, x) => s + x.duration, 0)).toBe(plan.effortStart + 90 + 300);
  });
});

function samples(count: number): RideSample[] {
  const start = Date.UTC(2026, 10, 15, 10, 0, 0);
  return Array.from({ length: count }, (_, i) => ({
    timestamp: start + i * 1000,
    elapsed: i + 1,
    power: 200 + (i % 7) * 10,
    cadence: 88,
    heartRate: i % 10 === 0 ? null : 140,
    speed: 9.5,
    distance: (i + 1) * 9.5,
    altitude: 240 + Math.sin(i / 20) * 5,
    gradePercent: 1.5,
  }));
}

describe("FIT", () => {
  it("schreibt und liest eine Fahrt verlustfrei", () => {
    const s = samples(600);
    const summary = computeSummary(s, s[0].timestamp, s[s.length - 1].timestamp + 1000);
    const fit = buildActivityFIT(s, [], summary);
    const fileCrc = fit[fit.length - 2] | (fit[fit.length - 1] << 8);
    expect(fitCrc(fit.subarray(0, fit.length - 2))).toBe(fileCrc);
    const back = rideFromFIT(fit);
    expect(back.samples).toHaveLength(600);
    expect(back.samples[10].power).toBe(s[10].power);
    expect(back.samples[10].heartRate).toBeNull();
    expect(back.samples[11].heartRate).toBe(140);
    expect(back.samples[599].distance).toBeCloseTo(s[599].distance, 1);
    expect(back.samples[50].altitude).toBeCloseTo(s[50].altitude, 0);
    expect(back.movingTime).toBe(600);
  });
  it("Normalized Power", () => {
    expect(normalizedPower(Array(100).fill(200))).toBe(200);
    expect(normalizedPower(Array(50).fill(100).concat(Array(50).fill(300)))).toBeGreaterThan(200);
  });
  const macRide = path.join(os.homedir(), "Library/Application Support/BikeApp/Rides/BikeApp-2026-11-12-1732.fit");
  it.skipIf(!fs.existsSync(macRide))("liest eine echte Fahrt der Mac-App", () => {
    const entry = entryFromFIT(new Uint8Array(fs.readFileSync(macRide)), "x.fit", "x", 250, new PowerZones());
    const meta = JSON.parse(fs.readFileSync(macRide + ".json", "utf8"));
    expect(entry.distance).toBeGreaterThan(0);
    if (meta.summary) expect(entry.summary?.avgPower).toBe(meta.summary.avgPower);
  });
});

describe("Fahr-Engine", () => {
  function setup(config: Partial<SessionConfig> = {}) {
    let now = Date.UTC(2026, 10, 15, 10, 0, 0);
    const live = new LiveSensors();
    const sent: unknown[] = [];
    const engine = new RideEngine(
      {
        name: "Test",
        courseTitle: "Flach",
        gradeRange: { min: 0, max: 2 },
        seed: 1,
        goal: { kind: "distance", meters: 2000 },
        workout: null,
        workoutMode: "ergOffset",
        presetTitle: "Flach",
        test: null,
        ...config,
      },
      { rider: riderParameters(), difficulty: 0.5, resistanceMode: "matchedSimulation", startGear: 12, trainerRatio: 34 / 14, measuredTrainerRatio: 0, setMeasuredTrainerRatio: () => undefined },
      { live, send: (c) => sent.push(c), hasMotionData: (t) => live.power(t) != null || live.cadence(t) != null, trainerSupportsSimulation: true },
      () => 250,
      () => now,
    );
    const step = (seconds: number, power: number | null, cadence = 90) => {
      for (let i = 0; i < seconds * 4; i++) {
        now += 250;
        if (power != null) {
          live.trainerPower = power;
          live.trainerCadence = cadence;
          live.trainerUpdated = now;
        }
        engine.tick();
      }
    };
    return { engine, step, sent };
  }

  it("fährt, zeichnet auf und pausiert automatisch", () => {
    const { engine, step, sent } = setup();
    engine.start(false);
    step(30, 220);
    expect(engine.phase).toBe("riding");
    expect(engine.distance).toBeGreaterThan(150);
    expect(engine.recorder.samples.length).toBeGreaterThanOrEqual(29);
    expect(sent.length).toBeGreaterThan(0);
    step(4, 0, 0);
    expect(engine.phase).toBe("paused");
  });
  it("endet am Ziel", () => {
    const { engine, step } = setup({ goal: { kind: "distance", meters: 300 } });
    let finished = false;
    engine.onFinish = () => (finished = true);
    engine.start(false);
    step(60, 250);
    expect(finished).toBe(true);
    expect(engine.phase).toBe("finished");
  });
  it("Workout im ERG: Ziel und ±5 W", () => {
    const { engine, step, sent } = setup({ goal: { kind: "workout" }, workout: Custom.asWorkout(Custom.templates()[1]) });
    engine.start(false);
    step(5, 150);
    expect(engine.isErgActive).toBe(true);
    const target = engine.targetWatts!;
    engine.shift("up");
    expect(engine.targetWatts).toBe(target + 5);
    expect(sent[sent.length - 1]).toEqual({ kind: "erg", watts: target + 5 });
    const snap = snapshotRide(engine, 250, new PowerZones());
    expect(snap.showsErgOffset).toBe(true);
    expect(snap.bottom).toBe("workout");
  });
  it("Ziel ändern während der Fahrt", () => {
    const { engine, step } = setup();
    engine.start(false);
    step(5, 200);
    engine.adjustGoal(1);
    expect(engine.config.goal).toEqual({ kind: "distance", meters: 5000 });
  });
});
