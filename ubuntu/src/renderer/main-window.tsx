// Main window: setup before a ride, live status during, summary after; history, devices, settings, editor.
import { useEffect, useMemo, useState } from "preact/hooks";
import { Fmt, PowerZones, Theme } from "../core/basics";
import { DeviceRole, roleInfo } from "../core/ble";
import { CoursePreset, ElevationProfile, coursePresets } from "../core/elevation";
import { resistanceModes, workoutModes } from "../core/engine";
import { RideEntry } from "../core/ride";
import { AppState, RideState, Settings, gradeRangeOf, isUsable, stateLabel } from "../core/state";
import {
  Block,
  BlockKind,
  Custom,
  CustomWorkout,
  WorkoutBlock,
  WorkoutStep,
  blockKindTitles,
  customIdPrefix,
  formatDuration,
  ftpTestKind,
  ftpTestKinds,
  makeTestPlan,
  parseDuration,
  testBasisText,
  Workout,
} from "../core/workout";
import { HeartRateLine, PowerBars, ProfileBars, WorkoutChart, ZoneDistributionBar, altitudeColumns } from "./charts";
import { DeviceDots, OVERLAY, OverlayBar } from "./ride";
import { Card, ChoiceChip, Icon, MetricLabel, Slider, Spinner, Stepper, Toggle, act, useNav } from "./store";
import { Scaled } from "./charts";

const set = (patch: Partial<Settings>) => act("settings.set", patch);
const zonesOf = (state: AppState) => new PowerZones(state.intervals.zones);

type Sheet = { kind: "devices" } | { kind: "settings" } | { kind: "editor"; workout: CustomWorkout } | null;

export function MainWindow(props: { state: AppState; ride: RideState | null; history: RideEntry[] }) {
  const { state, ride, history } = props;
  const [tab, setTab] = useState<"setup" | "history">("setup");
  const [sheet, setSheet] = useState<Sheet>(null);
  const [selectedWorkoutId, setSelectedWorkoutId] = useState<string | null>(null);
  useNav((target) => {
    if (target === "history" || target === "setup") setTab(target);
  });

  let content;
  if (state.finished) {
    content = <SummaryView state={state} history={history} openSettings={() => setSheet({ kind: "settings" })} />;
  } else if (state.isRiding && ride) {
    content = <RideStatusView state={state} ride={ride} />;
  } else {
    content = (
      <div class="col">
        <div class="row tabs">
          <ChoiceChip title="Neue Fahrt" selected={tab === "setup"} onClick={() => setTab("setup")} />
          <ChoiceChip title={history.length > 0 ? `Historie · ${history.length}` : "Historie"} selected={tab === "history"} onClick={() => setTab("history")} />
        </div>
        {tab === "setup" ? (
          <SetupView
            state={state}
            selectedWorkoutId={selectedWorkoutId}
            selectWorkout={setSelectedWorkoutId}
            openDevices={() => setSheet({ kind: "devices" })}
            openSettings={() => setSheet({ kind: "settings" })}
            edit={(workout) => setSheet({ kind: "editor", workout })}
          />
        ) : (
          <HistoryView state={state} history={history} openSettings={() => setSheet({ kind: "settings" })} />
        )}
      </div>
    );
  }

  return (
    <div class="main-window">
      {content}
      {sheet?.kind === "devices" ? <DevicesSheet state={state} close={() => setSheet(null)} /> : null}
      {sheet?.kind === "settings" ? <SettingsSheet state={state} close={() => setSheet(null)} /> : null}
      {sheet?.kind === "editor" ? (
        <WorkoutEditor
          state={state}
          initial={sheet.workout}
          close={() => setSheet(null)}
          saved={(id) => {
            setSelectedWorkoutId(id);
            setSheet(null);
          }}
        />
      ) : null}
    </div>
  );
}

function Modal(props: { title: string; close: () => void; width?: number; children: any; footer?: any }) {
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") props.close();
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, []);
  return (
    <div class="modal-backdrop" onClick={(e) => e.target === e.currentTarget && props.close()}>
      <div class="modal" role="dialog" aria-label={props.title} style={{ width: `${props.width ?? 600}px` }}>
        <div class="modal-body">{props.children}</div>
        {props.footer ? <div class="row modal-footer">{props.footer}</div> : null}
      </div>
    </div>
  );
}

// MARK: - Setup

function SetupView(props: {
  state: AppState;
  selectedWorkoutId: string | null;
  selectWorkout: (id: string | null) => void;
  openDevices: () => void;
  openSettings: () => void;
  edit: (workout: CustomWorkout) => void;
}) {
  const { state } = props;
  const s = state.settings;
  const [kind, setKind] = useState<"free" | "workout" | "ftpTest">("free");
  const [seed, setSeed] = useState(() => Math.floor(Math.random() * 999_999) + 1);

  const customWorkouts = state.customWorkouts.map(Custom.asWorkout);
  const intervalsWorkouts = state.intervals.configured ? [...state.intervals.upcoming, ...state.intervals.library] : [];
  const workouts = [...customWorkouts, ...intervalsWorkouts];
  const selected = workouts.find((w) => w.id === props.selectedWorkoutId) ?? workouts[0] ?? null;
  const canStart = kind !== "workout" || selected != null;

  const start = async () => {
    if (!canStart) return;
    if (kind === "ftpTest") await act("ride.start", { kind: "ftpTest", seed });
    else if (kind === "workout" && selected) await act("ride.start", { kind: "workout", seed, workoutId: selected.id });
    else await act("ride.start", { kind: "free", seed });
    setSeed(Math.floor(Math.random() * 999_999) + 1);
  };

  const ble = state.ble;
  const usable = (role: DeviceRole) => isUsable(ble.status[role]);
  const hints: string[] = [];
  if (!usable("trainer")) hints.push(usable("cadence") ? "Ohne Trainer: Tempo aus Kadenz und Gang, keine Watt" : "Ohne Trainer und Kadenz: nur Zeit und Puls, Pause von Hand");
  if (!usable("click") && !usable("clickLeft")) hints.push("ohne Click: schalten mit Strg+Alt+Bild↑/↓ oder in der Leiste");
  const hint = hints.length > 0 ? `${hints.join(" · ")}. Du kannst trotzdem starten.` : null;

  return (
    <div class="page">
      <div class="row">
        <div class="col">
          <h1>Bike App</h1>
          <span class="subtitle">Kickr Core 2 · Zwift Cog · Zwift Click</span>
        </div>
        <div class="grow" />
        <button class="button large" onClick={props.openSettings}>
          <Icon name="gear" /> Einstellungen
        </button>
      </div>

      <Card title="Geräte">
        <div class="device-grid">
          {ble.visibleRoles.map((role) => (
            <DeviceChip key={role} role={role} state={state} />
          ))}
        </div>
        <div class="row">
          {ble.isDemo ? (
            <span class="note accent">
              <Icon name="wand" /> Demo-Modus aktiv – Trainer, Puls und Kadenz werden simuliert.
            </span>
          ) : ble.adapter !== "poweredOn" && ble.adapter !== "unknown" ? (
            <span class="note warn">
              <Icon name="warning" /> {ble.adapterMessage ?? "Bluetooth ist nicht bereit."}
            </span>
          ) : null}
          <div class="grow" />
          <button class="button" onClick={props.openDevices}>
            Geräte verwalten…
          </button>
        </div>
      </Card>

      <Card title="Training">
        <div class="row gap8">
          <ChoiceChip title="Freie Fahrt" selected={kind === "free"} onClick={() => setKind("free")} />
          <ChoiceChip title="Workout" selected={kind === "workout"} onClick={() => setKind("workout")} />
          <ChoiceChip title="FTP-Test" selected={kind === "ftpTest"} onClick={() => setKind("ftpTest")} />
        </div>
        {kind === "free" ? (
          <>
            <CourseSection settings={s} seed={seed} reroll={() => setSeed(Math.floor(Math.random() * 999_999) + 1)} />
            <GoalSection settings={s} />
          </>
        ) : kind === "workout" ? (
          <WorkoutSection
            state={state}
            seed={seed}
            reroll={() => setSeed(Math.floor(Math.random() * 999_999) + 1)}
            customWorkouts={customWorkouts}
            intervalsWorkouts={intervalsWorkouts}
            selected={selected}
            select={props.selectWorkout}
            edit={props.edit}
            openSettings={props.openSettings}
          />
        ) : (
          <FTPTestSection state={state} />
        )}
      </Card>

      <Card title="Anzeige">
        <div class="row gap8">
          <ChoiceChip title="Leiste" selected={s.defaultDisplay === "bar"} onClick={() => set({ defaultDisplay: "bar" })} />
          <ChoiceChip title="Vollbild" selected={s.defaultDisplay === "fullscreen"} onClick={() => set({ defaultDisplay: "fullscreen" })} />
          <div class="grow" />
          <span class="secondary small">{s.defaultDisplay === "bar" ? "Schwebende Leiste über deiner Serie" : "Großes Dashboard im Vollbild"}</span>
        </div>
      </Card>

      <div class="row gap14">
        {hint ? (
          <span class="note warn wrap">
            <Icon name="info" /> {hint}
          </span>
        ) : null}
        <div class="grow" />
        <button class="start-button" disabled={!canStart} onClick={start}>
          Los geht's
        </button>
      </div>
    </div>
  );
}

function DeviceChip(props: { role: DeviceRole; state: AppState }) {
  const status = props.state.ble.status[props.role];
  const color = isUsable(status) ? Theme.ok : status.state === "notAssigned" ? "rgba(255,255,255,0.3)" : Theme.warn;
  return (
    <div class="device-chip" aria-label={`${roleInfo[props.role].title}: ${stateLabel(status)}`}>
      <span class="strong">{roleInfo[props.role].title}</span>
      <span class="secondary tiny ellipsis">{status.name ?? stateLabel(status)}</span>
      <span class="row gap6 tiny secondary">
        <span class="dot" style={{ width: "7px", height: "7px", background: color }} />
        <span class="ellipsis">{status.detail ?? stateLabel(status)}</span>
        {status.battery != null ? <span>{status.battery} %</span> : null}
      </span>
    </div>
  );
}

function CourseSection(props: { settings: Settings; seed: number; reroll: () => void }) {
  const s = props.settings;
  const range = gradeRangeOf(s);
  const length = s.goalKind === "distance" ? s.goalDistanceKm * 1000 : 20_000;
  const preview = useMemo(() => {
    const profile = new ElevationProfile(range, props.seed);
    return { columns: profile.columns(0, length, 150), ascent: profile.ascent(length) };
  }, [range.min, range.max, props.seed, length]);
  return (
    <div class="col gap12">
      <MetricLabel text="STRECKE" />
      <div class="row gap8">
        {coursePresets.map((p) => (
          <ChoiceChip key={p.id} title={p.title} selected={s.coursePreset === p.id} tint={Theme.gradeColor(p.range?.max ?? 6)} onClick={() => set({ coursePreset: p.id as CoursePreset })} />
        ))}
      </div>
      {s.coursePreset === "custom" ? (
        <div class="col gap6">
          <SliderRow title="Minimum" value={s.customMinGrade} min={-15} max={0} onInput={(v) => set({ customMinGrade: v })} />
          <SliderRow title="Maximum" value={s.customMaxGrade} min={0} max={20} onInput={(v) => set({ customMaxGrade: v })} />
        </div>
      ) : null}
      <ProfileBars columns={preview.columns} marker={null} spacing={2} minHeight={4} highlightCurrent={false} height={84} />
      <div class="row">
        <span class="secondary small">
          {Fmt.signedGrade(range.min)} bis +{Fmt.decimal(range.max, 0)} % · ↑ {Math.round(preview.ascent)} hm auf {Fmt.km(length)} km
        </span>
        <div class="grow" />
        <button class="button" onClick={props.reroll}>
          <Icon name="dice" /> Neu würfeln
        </button>
      </div>
    </div>
  );
}

function SliderRow(props: { title: string; value: number; min: number; max: number; onInput: (v: number) => void }) {
  return (
    <div class="row gap12">
      <span style={{ width: "80px" }}>{props.title}</span>
      <Slider value={props.value} min={props.min} max={props.max} step={0.5} onInput={props.onInput} />
      <span class="num" style={{ fontSize: "16px", fontWeight: 700, width: "60px", textAlign: "right" }}>
        {Fmt.signedGrade(props.value)} %
      </span>
    </div>
  );
}

function GoalSection(props: { settings: Settings }) {
  const s = props.settings;
  return (
    <div class="col gap12">
      <MetricLabel text="ZIEL" />
      <div class="row gap8">
        <ChoiceChip title="Distanz" selected={s.goalKind === "distance"} onClick={() => set({ goalKind: "distance" })} />
        <ChoiceChip title="Dauer" selected={s.goalKind === "duration"} onClick={() => set({ goalKind: "duration" })} />
      </div>
      {s.goalKind === "distance" ? (
        <div class="row gap12">
          <Slider value={s.goalDistanceKm} min={5} max={200} step={5} onInput={(v) => set({ goalDistanceKm: v })} />
          <span class="num big-value">{Math.trunc(s.goalDistanceKm)} km</span>
        </div>
      ) : (
        <div class="row gap12">
          <Slider value={s.goalDurationMin} min={10} max={300} step={5} onInput={(v) => set({ goalDurationMin: v })} />
          <span class="num big-value">{Fmt.clock(s.goalDurationMin * 60, true)}</span>
        </div>
      )}
    </div>
  );
}

function workoutSubtitle(w: Workout): string {
  const parts: string[] = [];
  if (w.id.startsWith(customIdPrefix)) parts.push("Eigenes Workout");
  else if (w.date) parts.push(new Date(w.date).toLocaleDateString("de-DE", { weekday: "long", day: "numeric", month: "short" }));
  else parts.push("Bibliothek");
  parts.push(Fmt.clock(w.steps.reduce((t, x) => t + x.duration, 0), true));
  return parts.join(" · ");
}

function Menu(props: { label: string; items: ({ title: string; action: () => void; danger?: boolean } | null)[] }) {
  const [open, setOpen] = useState(false);
  useEffect(() => {
    if (!open) return;
    const close = () => setOpen(false);
    window.addEventListener("click", close);
    return () => window.removeEventListener("click", close);
  }, [open]);
  return (
    <span class="menu">
      <button
        class="icon-button"
        aria-label={props.label}
        aria-expanded={open}
        onClick={(e) => {
          e.stopPropagation();
          setOpen(!open);
        }}
      >
        <Icon name="dots" size={18} />
      </button>
      {open ? (
        <div class="menu-list" role="menu">
          {props.items.map((item, i) =>
            item ? (
              <button key={i} role="menuitem" class={item.danger ? "danger" : ""} onClick={item.action}>
                {item.title}
              </button>
            ) : (
              <hr key={i} />
            ),
          )}
        </div>
      ) : null}
    </span>
  );
}

function WorkoutSection(props: {
  state: AppState;
  seed: number;
  reroll: () => void;
  customWorkouts: Workout[];
  intervalsWorkouts: Workout[];
  selected: Workout | null;
  select: (id: string | null) => void;
  edit: (w: CustomWorkout) => void;
  openSettings: () => void;
}) {
  const { state } = props;
  const s = state.settings;
  const zones = zonesOf(state);

  const row = (w: Workout) => {
    const custom = state.customWorkouts.find((c) => Custom.workoutId(c) === w.id);
    const selected = props.selected?.id === w.id;
    return (
      <div key={w.id} class={selected ? "workout-row selected" : "workout-row"}>
        <button class="row workout-row-main" onClick={() => props.select(w.id)} aria-pressed={selected}>
          <div class="col" style={{ width: "260px", flex: "none", alignItems: "flex-start" }}>
            <span class="strong ellipsis" style={{ maxWidth: "100%" }}>
              {w.name}
            </span>
            <span class="secondary tiny">{workoutSubtitle(w)}</span>
          </div>
          <div class="grow">
            <WorkoutChart steps={w.steps} elapsed={0} zones={zones} gap={1} minHeight={3} height={34} />
          </div>
        </button>
        <Menu
          label={`Aktionen für ${w.name}`}
          items={
            custom
              ? [
                  { title: "Bearbeiten…", action: () => props.edit(custom) },
                  { title: "Duplizieren", action: async () => props.select(await act("workouts.duplicate", custom.id)) },
                  { title: "Als intervals.icu-Text kopieren", action: () => act("clipboard.write", Custom.intervalsText(custom)) },
                  null,
                  {
                    title: "Löschen",
                    danger: true,
                    action: () => {
                      act("workouts.delete", custom.id);
                      if (props.selected?.id === w.id) props.select(null);
                    },
                  },
                ]
              : [{ title: "Als eigenes Workout bearbeiten…", action: () => props.edit(Custom.from(w)) }]
          }
        />
      </div>
    );
  };

  const load = state.intervals.load;
  return (
    <div class="col gap12">
      <div class="row">
        <MetricLabel text="EIGENE WORKOUTS" />
        <div class="grow" />
        <button class="button" onClick={() => props.edit(Custom.make("Neues Workout", Custom.templates()[0].blocks))}>
          <Icon name="plus" /> Neues Workout
        </button>
      </div>
      {props.customWorkouts.length === 0 ? (
        <span class="secondary small">Noch keine eigenen Workouts. Erstelle eins mit „Neues Workout“ oder kopiere ein intervals.icu-Workout über das Menü (…) in seiner Zeile.</span>
      ) : (
        <div class="col gap8">{props.customWorkouts.map(row)}</div>
      )}

      {!state.intervals.configured ? (
        <div class="col gap6" style={{ marginTop: "6px" }}>
          <MetricLabel text="INTERVALS.ICU" />
          <span class="secondary small">Verbinde intervals.icu, um geplante Workouts zu laden. Den API-Key findest du dort unter Einstellungen › Developer Settings.</span>
          <button class="link-button" onClick={props.openSettings}>
            Einstellungen öffnen
          </button>
        </div>
      ) : (
        <div class="col gap12" style={{ marginTop: "6px" }}>
          <div class="row gap8">
            <MetricLabel text="INTERVALS.ICU · GEPLANT (7 TAGE) UND BIBLIOTHEK" />
            <div class="grow" />
            {load.kind === "loading" ? <Spinner /> : load.kind === "failed" ? <span class="bad tiny">{load.message}</span> : null}
            <button class="button" onClick={() => act("intervals.refresh")}>
              <Icon name="refresh" /> Aktualisieren
            </button>
          </div>
          {props.intervalsWorkouts.length === 0 ? (
            <span class="secondary small">Keine Rad-Workouts gefunden. Lege in intervals.icu ein Workout vom Typ Ride oder Virtual Ride in den Kalender oder die Bibliothek.</span>
          ) : (
            <div class="col gap8">{props.intervalsWorkouts.map(row)}</div>
          )}
        </div>
      )}

      <MetricLabel text="MODUS" />
      <div class="row gap8">
        {workoutModes.map((m) => (
          <ChoiceChip key={m.id} title={m.title} selected={s.workoutMode === m.id} onClick={() => set({ workoutMode: m.id })} />
        ))}
      </div>
      <span class="secondary small">{workoutModes.find((m) => m.id === s.workoutMode)?.detail}</span>
      {s.workoutMode === "simTargets" ? <CourseSection settings={s} seed={props.seed} reroll={props.reroll} /> : null}
      {state.intervals.athleteFTP == null || !s.useIntervalsFTP ? (
        <span class="secondary tiny">FTP für die Ziele: {state.intervals.effectiveFTP} W (aus den Einstellungen)</span>
      ) : null}
    </div>
  );
}

function FTPTestSection(props: { state: AppState }) {
  const { state } = props;
  const s = state.settings;
  const known = s.useIntervalsFTP && state.intervals.athleteFTP != null;
  const plan = makeTestPlan(s.ftpTestKind, state.intervals.effectiveFTP, known);
  const steps: WorkoutStep[] = plan.kind === "ramp" ? plan.workout.steps.filter((x) => (x.startFraction ?? 0) <= 1.4 || x.label === "Ausfahren") : plan.workout.steps;
  const top = Math.max(1.2, Math.max(...steps.map((x) => x.startFraction ?? 0)) * 1.05);
  const duration = plan.kind === "ramp" ? "ca. 20–30 min" : `ca. ${Math.round(plan.workout.steps.reduce((t, x) => t + x.duration, 0) / 60)} min`;
  return (
    <div class="col gap12">
      <MetricLabel text="TEST" />
      <div class="row gap8">
        {ftpTestKinds.map((k) => (
          <ChoiceChip key={k.id} title={k.title} selected={s.ftpTestKind === k.id} onClick={() => set({ ftpTestKind: k.id })} />
        ))}
      </div>
      <span class="secondary small">{ftpTestKind(plan.kind).detail}</span>
      <WorkoutChart steps={steps} elapsed={0} zones={zonesOf(state)} gap={1} minHeight={3} top={top} height={70} />
      <div class="row secondary tiny">
        <span>
          Ausgangswert für die Ziele: {plan.baseFTP} W ({known ? "aus intervals.icu" : "aus den Einstellungen"})
        </span>
        <div class="grow" />
        <span>{duration}</span>
      </div>
      <span class="small">
        {plan.kind === "ramp"
          ? "Wenn du nicht mehr kannst: aufhören zu treten, beide Click-Tasten drücken oder „Test beenden“ in der Leiste."
          : "In den 20 Minuten hält der Kickr keine Watt: Schalte mit dem Click und fahre so gleichmäßig wie möglich."}
      </span>
      <Toggle label="Ergebnis automatisch als neue FTP übernehmen (App und intervals.icu)" checked={s.autoTransferFTP} onChange={(v) => set({ autoTransferFTP: v })} />
      {!state.intervals.configured ? <span class="secondary tiny">Ohne API-Key wird das Ergebnis zu intervals.icu übertragen, sobald du ihn einträgst.</span> : null}
    </div>
  );
}

// MARK: - During the ride

function RideStatusView(props: { state: AppState; ride: RideState }) {
  const { state, ride } = props;
  const width = Math.min(window.innerWidth - 56, 1100);
  return (
    <div class="page">
      <div class="row">
        <div class="col">
          <h2>{ride.name}</h2>
          <span class="subtitle">{ride.phaseText}</span>
        </div>
        <div class="grow" />
        <DeviceDots state={state} />
      </div>
      <Scaled width={OVERLAY.baseWidth} height={OVERLAY.barHeight} scale={width / OVERLAY.baseWidth}>
        <OverlayBar ride={ride} state={state} opacity={0.9} controls={false} interactive={false} />
      </Scaled>
      <div class="row gap12">
        <button class="button large" onClick={() => act("ride.togglePause")}>
          {ride.phase === "paused" ? "Weiter" : "Pause"}
        </button>
        <button class="button large danger" onClick={() => act("ride.stop")}>
          Fahrt beenden
        </button>
        <div class="grow" />
        <div class="segmented" role="group" aria-label="Anzeige">
          <button aria-pressed={state.displayMode === "bar"} onClick={() => act("display.set", "bar")}>
            Leiste
          </button>
          <button aria-pressed={state.displayMode === "fullscreen"} onClick={() => act("display.set", "fullscreen")}>
            Vollbild
          </button>
        </div>
      </div>
      {state.ftpOutcome ? <FTPResultCard state={state} /> : null}
      {ride.canChangeGoal ? <GoalEditor ride={ride} /> : null}
      <Card title="Tastenkürzel">
        <div class="shortcuts">
          {[
            ["Click + / −", "Schwerer / leichter schalten"],
            ["Click + und −", "Beide zusammen: Pause / weiter"],
            ["Strg+Alt+Bild↑ / Bild↓", "Schalten (ohne Click)"],
            ["Strg+Alt+P", "Pause / weiter"],
            ["Strg+Alt+F", "Leiste ↔ Vollbild"],
            ["Strg+Alt+B", "Leiste ein / aus"],
            ["Strg+Alt+K", "Leiste durchklickbar (für den Videoplayer)"],
          ].map(([keys, text]) => (
            <>
              <span class="mono accent-soft">{keys}</span>
              <span>{text}</span>
            </>
          ))}
        </div>
        {!state.shortcutsActive ? (
          <span class="note warn small">
            <Icon name="warning" /> Die globalen Tastenkürzel ließen sich nicht registrieren. Du kannst im System eigene Kürzel auf „bike-app --action=pause“ usw. legen (siehe README).
          </span>
        ) : null}
        <span class="secondary small">Die Leiste lässt sich ziehen und über die rechte untere Ecke größer oder kleiner machen. Doppelklick wechselt ins Vollbild.</span>
      </Card>
    </div>
  );
}

/** Change distance or duration during a free ride. */
function GoalEditor(props: { ride: RideState }) {
  const r = props.ride;
  const minimumKm = Math.max(1, Math.ceil((r.distance + 500) / 1000));
  const minimumMin = Math.max(5, Math.ceil((r.movingTime + 60) / 60));
  const [kind, setKind] = useState<"distance" | "duration">(r.goal.kind === "duration" ? "duration" : "distance");
  const [km, setKm] = useState(r.goal.kind === "distance" ? Math.max(minimumKm, Math.round(r.goal.meters / 1000)) : Math.max(minimumKm, 30));
  const [min, setMin] = useState(r.goal.kind === "duration" ? Math.max(minimumMin, Math.round(r.goal.seconds / 60)) : Math.max(minimumMin, 60));
  return (
    <Card title="Ziel ändern">
      <div class="row gap8">
        <ChoiceChip title="Distanz" selected={kind === "distance"} onClick={() => setKind("distance")} />
        <ChoiceChip title="Dauer" selected={kind === "duration"} onClick={() => setKind("duration")} />
        <div class="grow" />
        <span class="secondary small">Aktuell: {r.goalLabel}</span>
      </div>
      <div class="row gap14">
        {kind === "distance" ? (
          <>
            <Slider value={Math.max(km, minimumKm)} min={minimumKm} max={300} step={1} onInput={setKm} />
            <span class="num big-value">{Math.max(km, minimumKm)} km</span>
          </>
        ) : (
          <>
            <Slider value={Math.max(min, minimumMin)} min={minimumMin} max={360} step={5} onInput={setMin} />
            <span class="num big-value">{Fmt.clock(Math.max(min, minimumMin) * 60, true)}</span>
          </>
        )}
        <button
          class="button large"
          onClick={() => act("ride.setGoal", kind === "distance" ? { kind: "distance", meters: Math.max(km, minimumKm) * 1000 } : { kind: "duration", seconds: Math.max(min, minimumMin) * 60 })}
        >
          Übernehmen
        </button>
      </div>
      <span class="secondary tiny">
        {kind === "distance" ? "Längere Strecken werden einfach weitergeneriert, das bisherige Profil bleibt." : "Bei einer Dauer zeigt die Leiste die nächsten Kilometer als mitlaufendes Profil."}
      </span>
    </Card>
  );
}

// MARK: - FTP result

function FTPResultCard(props: { state: AppState }) {
  const { state } = props;
  const outcome = state.ftpOutcome!;
  const result = outcome.result;
  const delta = result.ftp - outcome.previousAppFTP;
  const t = outcome.transfer;
  const configured = state.intervals.configured;
  let row;
  switch (t.kind) {
    case "idle":
      row = (
        <>
          <Icon name={outcome.applied ? "check" : "info"} color={outcome.applied ? Theme.ok : Theme.secondary} />
          <span>{outcome.applied ? "Als FTP in der App gespeichert." : "Noch nicht übernommen."}</span>
          <div class="grow" />
          {!outcome.applied ? (
            <button class="button" onClick={() => act("ftp.apply", state.settings.autoTransferFTP)}>
              Übernehmen
            </button>
          ) : null}
          <button class="button" disabled={!configured} onClick={() => (outcome.applied ? act("ftp.transfer") : act("ftp.apply", true))}>
            Zu intervals.icu übertragen
          </button>
          {outcome.applied ? (
            <button class="button" onClick={() => act("ftp.undo")}>
              Rückgängig
            </button>
          ) : null}
        </>
      );
      break;
    case "waitingForKey":
      row = (
        <>
          <Icon name="clock" color={Theme.warn} />
          <span>In der App gespeichert. Wird zu intervals.icu übertragen, sobald du den API-Key einträgst.</span>
          <div class="grow" />
          <button class="button" onClick={() => act("ftp.undo")}>
            Rückgängig
          </button>
        </>
      );
      break;
    case "sending":
      row = (
        <>
          <Spinner /> <span>Wird zu intervals.icu übertragen…</span>
        </>
      );
      break;
    case "transferred":
      row = (
        <>
          <Icon name="check" color={Theme.ok} />
          <span>
            In der App und in intervals.icu übernommen ({t.change.field === "indoor_ftp" ? "Indoor-FTP" : "FTP"}: {t.change.previous != null ? `${t.change.previous} W` : "leer"} →{" "}
            {t.change.new != null ? `${t.change.new} W` : "leer"}).
          </span>
          <div class="grow" />
          <button class="button" onClick={() => act("ftp.undo")}>
            Rückgängig
          </button>
        </>
      );
      break;
    case "undone":
      row = (
        <>
          <Icon name="undo" color={Theme.secondary} />
          <span>Zurückgesetzt, die FTP ist wieder {outcome.previousAppFTP} W.</span>
          <div class="grow" />
          <button class="button" onClick={() => act("ftp.apply", true)}>
            Doch übernehmen
          </button>
        </>
      );
      break;
    case "failed":
      row = (
        <>
          <Icon name="warning" color={Theme.bad} />
          <span>{t.message}</span>
          <div class="grow" />
          <button class="button" onClick={() => act("ftp.transfer")}>
            Erneut versuchen
          </button>
        </>
      );
      break;
    case "needsConfirmation":
      row = (
        <>
          <Icon name="warning" color={Theme.warn} />
          <div class="col">
            <span>Nicht automatisch übernommen.</span>
            <span class="secondary tiny">{t.reason}</span>
          </div>
          <div class="grow" />
          <button class="button" onClick={() => act("ftp.apply", true)}>
            Trotzdem übernehmen
          </button>
        </>
      );
      break;
  }
  return (
    <Card title={`FTP-Test · ${ftpTestKind(result.kind).title}`}>
      <div class="row gap12" style={{ alignItems: "baseline" }}>
        <span class="num" style={{ fontSize: "64px", fontWeight: 800, color: Theme.accent }}>
          {result.ftp}
        </span>
        <span style={{ fontSize: "18px", color: Theme.label }}>W FTP</span>
        <span style={{ fontSize: "18px", fontWeight: 600 }}>{Fmt.decimal(result.ftp / Math.max(30, state.settings.riderWeight), 1)} W/kg</span>
        <div class="grow" />
        <div class="col" style={{ alignItems: "flex-end" }}>
          <span class="num" style={{ fontSize: "24px", fontWeight: 700, color: delta >= 0 ? Theme.ok : Theme.warn }}>
            {delta === 0 ? "unverändert" : `${delta > 0 ? "+" : "−"}${Math.abs(delta)} W`}
          </span>
          <span class="secondary tiny">vorher {outcome.previousAppFTP} W</span>
        </div>
      </div>
      <span class="secondary small">{testBasisText(result)}</span>
      <div class="row gap10 wrap-row">{row}</div>
    </Card>
  );
}

// MARK: - After the ride

function SummaryView(props: { state: AppState; history: RideEntry[]; openSettings: () => void }) {
  const { state } = props;
  const finished = state.finished!;
  const entry = props.history.find((e) => e.id === finished.filename);
  const u = finished.uploadState;
  let upload;
  switch (u.kind) {
    case "idle":
      upload = (
        <>
          <span class="secondary">Gesichert, noch nicht hochgeladen.</span>
          <div class="grow" />
          <button class="button" disabled={!state.intervals.configured} onClick={() => act("finished.upload")}>
            Hochladen
          </button>
        </>
      );
      break;
    case "waitingForKey":
      upload = (
        <>
          <Icon name="check" color={Theme.ok} />
          <div class="col">
            <span>Fahrt gesichert. Sie wird automatisch hochgeladen, sobald du einen API-Key einträgst.</span>
            <span class="secondary tiny">Du kannst die App auch schließen, die Fahrt geht nicht verloren.</span>
          </div>
          <div class="grow" />
          <button class="button" onClick={props.openSettings}>
            API-Key eintragen
          </button>
        </>
      );
      break;
    case "uploading":
      upload = (
        <>
          <Spinner /> <span>Wird hochgeladen…</span>
        </>
      );
      break;
    case "uploaded":
      upload = (
        <>
          <Icon name="check" color={Theme.ok} /> <span>Hochgeladen</span>
          {u.id ? (
            <button class="link-button" onClick={() => act("open.external", `https://intervals.icu/activities/${u.id}`)}>
              In intervals.icu öffnen
            </button>
          ) : null}
        </>
      );
      break;
    case "queued":
    case "failed":
      upload = (
        <>
          <Icon name={u.kind === "queued" ? "clock" : "warning"} color={u.kind === "queued" ? Theme.warn : Theme.bad} />
          <div class="col">
            <span>{u.kind === "queued" ? "Upload fehlgeschlagen. Die Fahrt ist gesichert und wird später automatisch erneut hochgeladen." : u.message}</span>
            {u.kind === "queued" ? <span class="secondary tiny">{u.message}</span> : null}
          </div>
          <div class="grow" />
          <button class="button" onClick={() => act("finished.upload")}>
            Nochmal
          </button>
        </>
      );
      break;
  }
  return (
    <div class="page">
      <div class="col">
        <h1>Geschafft!</h1>
        <span class="subtitle">{finished.name}</span>
      </div>
      {state.ftpOutcome ? <FTPResultCard state={state} /> : null}
      <Card title="intervals.icu">
        <div class="row gap10">{upload}</div>
      </Card>
      {entry ? <RideDetailContent entry={entry} state={state} /> : null}
      <div class="row gap12">
        <button class="button large" onClick={() => act("rides.export", finished.filename)}>
          FIT exportieren…
        </button>
        <div class="grow" />
        <span class="secondary small">Die Fahrt ist in der Historie gespeichert.</span>
        <button class="start-button small" onClick={() => act("ride.discard")}>
          Fertig
        </button>
      </div>
    </div>
  );
}

// MARK: - History

function HistoryView(props: { state: AppState; history: RideEntry[]; openSettings: () => void }) {
  const [selection, setSelection] = useState<string | null>(null);
  const entry = selection ? props.history.find((e) => e.id === selection) : null;
  if (entry) return <RideDetailView entry={entry} state={props.state} back={() => setSelection(null)} />;
  return <HistoryList {...props} select={setSelection} />;
}

const dateLine = (iso: string) =>
  new Date(iso)
    .toLocaleString("de-DE", { weekday: "short", day: "numeric", month: "short", hour: "2-digit", minute: "2-digit" })
    .replace(",", " ·")
    .toUpperCase();

const longDate = (iso: string) =>
  `${new Date(iso).toLocaleDateString("de-DE", { weekday: "long", day: "numeric", month: "long", year: "numeric" })} · ${new Date(iso).toLocaleTimeString("de-DE", {
    hour: "2-digit",
    minute: "2-digit",
  })} Uhr`;

function HistoryList(props: { state: AppState; history: RideEntry[]; openSettings: () => void; select: (id: string) => void }) {
  const { state, history } = props;
  const [message, setMessage] = useState<string | null>(null);
  const importFIT = async () => {
    const failed = await act("rides.import");
    if (failed != null) setMessage(failed === 0 ? "Importiert" : `${failed} Datei(en) konnten nicht gelesen werden`);
  };
  return (
    <div class="page">
      <div class="row">
        <div class="col">
          <h1>Historie</h1>
          <span class="subtitle">{history.length === 0 ? "Noch keine Fahrten" : `${history.length} Fahrt${history.length === 1 ? "" : "en"}`}</span>
        </div>
        <div class="grow" />
        {message ? <span class="secondary tiny">{message}</span> : null}
        <button class="button large" onClick={importFIT}>
          <Icon name="download" /> Fahrt importieren…
        </button>
      </div>
      {history.length === 0 ? (
        <Card>
          <span class="strong">Hier erscheinen deine Fahrten.</span>
          <span class="secondary small">Jede Fahrt wird nach dem Ende automatisch gesichert. Eine früher gesicherte FIT-Datei kannst du über „Fahrt importieren…“ hinzufügen.</span>
        </Card>
      ) : (
        <>
          <WeekOverview entries={history} />
          {state.pendingUploads > 0 ? (
            <div class="row gap12 banner">
              <Icon name="clock" color={Theme.warn} />
              <span>
                {state.intervals.configured ? `${state.pendingUploads} Fahrt(en) noch nicht bei intervals.icu.` : `${state.pendingUploads} Fahrt(en) warten auf einen API-Key für intervals.icu.`}
              </span>
              <div class="grow" />
              {state.intervals.configured ? (
                <button class="button" onClick={() => act("rides.sync")}>
                  Jetzt hochladen
                </button>
              ) : (
                <button class="button" onClick={props.openSettings}>
                  API-Key eintragen
                </button>
              )}
            </div>
          ) : null}
          <div class="col gap10">
            {history.map((entry) => (
              <RideRow key={entry.id} entry={entry} state={state} onClick={() => props.select(entry.id)} />
            ))}
          </div>
        </>
      )}
    </div>
  );
}

/** Monday 00:00 of the ISO week of `date`. */
function weekStart(date: Date): Date {
  const d = new Date(date.getFullYear(), date.getMonth(), date.getDate());
  d.setDate(d.getDate() - ((d.getDay() + 6) % 7));
  return d;
}

function isoWeek(date: Date): number {
  const d = new Date(Date.UTC(date.getFullYear(), date.getMonth(), date.getDate()));
  d.setUTCDate(d.getUTCDate() + 4 - (d.getUTCDay() || 7));
  const yearStart = new Date(Date.UTC(d.getUTCFullYear(), 0, 1));
  return Math.ceil(((d.getTime() - yearStart.getTime()) / 86_400_000 + 1) / 7);
}

export function weeks(entries: RideEntry[], count = 8, now = new Date()) {
  const current = weekStart(now);
  const result = [];
  for (let back = count - 1; back >= 0; back--) {
    const start = new Date(current);
    start.setDate(start.getDate() - back * 7);
    const end = new Date(start);
    end.setDate(end.getDate() + 7);
    const rides = entries.filter((e) => {
      const t = Date.parse(e.date);
      return t >= start.getTime() && t < end.getTime();
    });
    result.push({
      label: `KW ${isoWeek(start)}`,
      hours: rides.reduce((s, e) => s + e.movingTime, 0) / 3600,
      km: rides.reduce((s, e) => s + e.distance, 0) / 1000,
    });
  }
  return result;
}

function WeekOverview(props: { entries: RideEntry[] }) {
  const list = weeks(props.entries);
  const thisWeek = props.entries.filter((e) => Date.parse(e.date) >= weekStart(new Date()).getTime());
  const month = props.entries.filter((e) => Date.parse(e.date) >= Date.now() - 30 * 86_400_000);
  const maxHours = Math.max(1, ...list.map((w) => w.hours));
  const niceTop = maxHours <= 2 ? Math.ceil(maxHours * 2) / 2 : Math.ceil(maxHours);
  const tile = (title: string, rides: RideEntry[]) => {
    const km = rides.reduce((s, e) => s + e.distance, 0) / 1000;
    const seconds = rides.reduce((s, e) => s + e.movingTime, 0);
    const kj = rides.reduce((s, e) => s + (e.summary?.kilojoules ?? 0), 0);
    const figure = (value: string, unit: string) => (
      <span class="baseline">
        <span class="num" style={{ fontSize: "22px", fontWeight: 700 }}>
          {value}
        </span>
        <span class="unit-small">{unit}</span>
      </span>
    );
    return (
      <div class="stat-tile">
        <MetricLabel text={title} />
        <div class="row gap14">
          {figure(String(rides.length), rides.length === 1 ? "Fahrt" : "Fahrten")}
          {figure(Fmt.decimal(km, km < 100 ? 1 : 0), "km")}
          {figure(Fmt.clock(seconds, true).slice(0, -3), "h")}
          {figure(String(Math.round(kj)), "kJ")}
        </div>
      </div>
    );
  };
  return (
    <div class="row gap14" style={{ alignItems: "stretch" }}>
      <div class="col gap14" style={{ width: "360px", flex: "none" }}>
        {tile("DIESE WOCHE", thisWeek)}
        {tile("LETZTE 30 TAGE", month)}
      </div>
      <Card title="Stunden pro Woche" class="grow">
        <div class="week-chart">
          <div class="week-axis">
            <span>{Fmt.decimal(niceTop, niceTop < 10 ? 1 : 0)} h</span>
            <span>{Fmt.decimal(niceTop / 2, niceTop < 10 ? 1 : 0)} h</span>
            <span>0 h</span>
          </div>
          {list.map((w, i) => (
            <div key={w.label} class="week-col" title={`${w.label}: ${Fmt.decimal(w.hours, 1)} h, ${Fmt.decimal(w.km, 1)} km`}>
              <div class="week-bar-area">
                <span class="week-bar" style={{ height: `${(w.hours / niceTop) * 100}%`, background: i === list.length - 1 ? Theme.accent : "rgba(255,107,26,0.45)" }} />
              </div>
              <span class="tiny secondary">{w.label}</span>
            </div>
          ))}
        </div>
      </Card>
    </div>
  );
}

function UploadBadge(props: { entry: RideEntry; configured: boolean }) {
  const e = props.entry;
  const [text, icon, color] = e.uploadedActivityId
    ? ["intervals.icu", "check", Theme.ok]
    : !props.configured
      ? ["wartet auf API-Key", "clock", Theme.warn]
      : e.lastError
        ? ["Upload fehlgeschlagen", "warning", Theme.bad]
        : ["noch nicht hochgeladen", "clock", Theme.warn];
  return (
    <span class="badge" style={{ color, background: `${color}24` }}>
      <Icon name={icon} size={12} /> {text}
    </span>
  );
}

function RideRow(props: { entry: RideEntry; state: AppState; onClick: () => void }) {
  const { entry, state } = props;
  const s = entry.summary;
  const metric = (value: string, unit = "") => (
    <span class="baseline nowrap">
      <span class="num" style={{ fontSize: "18px", fontWeight: 700 }}>
        {value}
      </span>
      {unit ? <span class="unit-small">{unit}</span> : null}
    </span>
  );
  return (
    <button class="ride-row" onClick={props.onClick} aria-label={`${entry.name}, ${dateLine(entry.date)}`}>
      <div class="col gap6" style={{ width: "400px", flex: "none", alignItems: "flex-start" }}>
        <div class="row gap8">
          <span class="tiny strong secondary" style={{ letterSpacing: "0.9px" }}>
            {dateLine(entry.date)}
          </span>
          <UploadBadge entry={entry} configured={state.intervals.configured} />
        </div>
        <div class="row gap8" style={{ maxWidth: "100%" }}>
          <span class="ellipsis" style={{ fontSize: "16px", fontWeight: 600 }}>
            {entry.name}
          </span>
          {entry.ftpTestResult ? <span class="ftp-badge">FTP {entry.ftpTestResult} W</span> : null}
        </div>
        <div class="row gap14">
          {metric(Fmt.km(entry.distance), "km")}
          {metric(Fmt.clock(entry.movingTime, true))}
          {s ? metric(String(s.avgPower), "W Ø") : null}
          {s && s.ascent >= 1 ? metric(`↑ ${Math.round(s.ascent)}`, "hm") : null}
          {s?.avgHeartRate ? metric(`♥ ${s.avgHeartRate}`) : null}
        </div>
      </div>
      <div class="col gap6 grow">
        <PowerBars power={entry.series?.power ?? []} ftp={entry.ftp ?? state.intervals.effectiveFTP} zones={zonesOf(state)} height={44} />
        <ZoneDistributionBar seconds={entry.zoneSeconds ?? []} height={6} />
      </div>
      <Icon name="chevronRight" color={Theme.label} />
    </button>
  );
}

function RideDetailView(props: { entry: RideEntry; state: AppState; back: () => void }) {
  const { entry, state } = props;
  const [uploading, setUploading] = useState(false);
  const [confirm, setConfirm] = useState(false);
  return (
    <div class="page">
      <div class="row gap12">
        <button class="link-button" onClick={props.back}>
          <Icon name="chevronLeft" /> Historie
        </button>
        <div class="grow" />
        {!entry.uploadedActivityId ? (
          <>
            {uploading ? <Spinner /> : null}
            <button
              class="button large"
              disabled={!state.intervals.configured || uploading}
              onClick={async () => {
                setUploading(true);
                await act("rides.upload", entry.id);
                setUploading(false);
              }}
            >
              Hochladen
            </button>
          </>
        ) : entry.uploadedActivityId !== "ok" ? (
          <button class="link-button" onClick={() => act("open.external", `https://intervals.icu/activities/${entry.uploadedActivityId}`)}>
            In intervals.icu öffnen
          </button>
        ) : null}
        <button class="button large" onClick={() => act("rides.export", entry.id)}>
          FIT exportieren…
        </button>
        <button class="button large danger" onClick={() => setConfirm(true)}>
          Löschen
        </button>
      </div>
      <div class="col gap6">
        <div class="row gap10">
          <h2>{entry.name}</h2>
          <UploadBadge entry={entry} configured={state.intervals.configured} />
        </div>
        <span class="subtitle">{[longDate(entry.date), entry.subtitle].filter(Boolean).join(" · ")}</span>
        {entry.lastError && !entry.uploadedActivityId ? <span class="bad tiny">Letzter Upload-Versuch: {entry.lastError}</span> : null}
      </div>
      <RideDetailContent entry={entry} state={state} />
      {confirm ? (
        <Modal
          title="Fahrt löschen?"
          close={() => setConfirm(false)}
          width={440}
          footer={
            <>
              <div class="grow" />
              <button class="button" onClick={() => setConfirm(false)}>
                Abbrechen
              </button>
              <button
                class="button danger"
                onClick={() => {
                  act("rides.delete", entry.id);
                  props.back();
                }}
              >
                Löschen
              </button>
            </>
          }
        >
          <h3>Fahrt löschen?</h3>
          <p class="secondary">
            {entry.uploadedActivityId
              ? "Die Fahrt wird nur auf diesem Rechner gelöscht. In intervals.icu bleibt sie erhalten."
              : "Die Fahrt ist noch nicht bei intervals.icu und geht damit endgültig verloren."}
          </p>
        </Modal>
      ) : null}
    </div>
  );
}

function StatTile(props: { label: string; value: string; unit?: string | null; color?: string }) {
  return (
    <div class="stat-tile">
      <MetricLabel text={props.label} />
      <span class="baseline nowrap">
        <span class="num" style={{ fontSize: "30px", fontWeight: 700, color: props.color ?? "#fff" }}>
          {props.value}
        </span>
        {props.unit ? <span class="unit-small" style={{ fontSize: "13px" }}>{props.unit}</span> : null}
      </span>
    </div>
  );
}

/** Figures, zones and charts of one ride (used in the history and after a ride). */
function RideDetailContent(props: { entry: RideEntry; state: AppState }) {
  const { entry, state } = props;
  const zones = zonesOf(state);
  const ftp = entry.ftp ?? state.intervals.effectiveFTP;
  const s = entry.summary;
  const series = entry.series;
  const total = series ? series.power.length * series.bucketSeconds : 0;
  const timeAxis = (
    <div class="row axis">
      {[0, 1, 2, 3, 4].map((i) => (
        <span key={i}>{Fmt.clock((total * i) / 4, false)}</span>
      ))}
    </div>
  );
  const minutes = (seconds: number) => (seconds >= 3600 ? Fmt.clock(seconds, true) : `${Math.round(seconds / 60)} min`);
  const columns = series ? altitudeColumns(series) : [];
  return (
    <div class="col gap16">
      {s ? (
        <div class="stat-grid">
          <StatTile label="ZEIT" value={Fmt.clock(s.movingTime, true)} />
          <StatTile label="DISTANZ" value={Fmt.km(s.distance)} unit="km" />
          <StatTile label="Ø GESCHWINDIGKEIT" value={Fmt.decimal(s.avgSpeed * 3.6, 1)} unit="km/h" />
          <StatTile label="HÖHENMETER" value={String(Math.round(s.ascent))} unit="m" />
          <StatTile label="Ø LEISTUNG" value={String(s.avgPower)} unit="W" color={Theme.zoneColor(zones.index(s.avgPower, ftp))} />
          <StatTile label="NP" value={String(s.normalizedPower)} unit="W" color={Theme.zoneColor(zones.index(s.normalizedPower, ftp))} />
          <StatTile label="MAX" value={String(s.maxPower)} unit="W" />
          <StatTile label="ARBEIT" value={String(Math.round(s.kilojoules))} unit="kJ" />
          <StatTile label="Ø TRITTFREQUENZ" value={s.avgCadence != null ? String(s.avgCadence) : "–"} unit="rpm" />
          <StatTile label="Ø PULS" value={s.avgHeartRate != null ? String(s.avgHeartRate) : "–"} unit="bpm" />
          <StatTile label="MAX PULS" value={s.maxHeartRate != null ? String(s.maxHeartRate) : "–"} unit="bpm" />
          <StatTile label="FTP" value={String(ftp)} unit="W" />
        </div>
      ) : (
        <Card>
          <span class="secondary">Für diese Fahrt liegen keine Details vor.</span>
        </Card>
      )}
      {entry.zoneSeconds && entry.zoneSeconds.some((x) => x > 0) ? (
        <Card title="Zeit in Zonen">
          <ZoneDistributionBar seconds={entry.zoneSeconds} height={14} />
          <div class="row gap18 wrap-row">
            {entry.zoneSeconds.map((value, i) =>
              value > 0 ? (
                <span key={i} class="row gap6 tiny">
                  <span style={{ width: "10px", height: "10px", borderRadius: "3px", background: Theme.zoneColor(i) }} />
                  <span class="secondary">
                    {PowerZones.shortName(i)} {PowerZones.zoneName(i)}
                  </span>
                  <b>{minutes(value)}</b>
                </span>
              ) : null,
            )}
          </div>
        </Card>
      ) : null}
      {series && series.power.length > 0 ? (
        <>
          <Card title="Leistung">
            <PowerBars power={series.power} ftp={ftp} zones={zones} height={150} />
            {timeAxis}
          </Card>
          {series.heartRate.some((x) => x > 0) ? (
            <Card title="Puls">
              <HeartRateLine values={series.heartRate} height={90} />
              {timeAxis}
            </Card>
          ) : null}
          {columns.length > 0 ? (
            <Card title="Höhenprofil">
              <ProfileBars columns={columns} marker={null} spacing={1} minHeight={4} highlightCurrent={false} height={90} />
              <div class="row axis">
                <span>0 km</span>
                <span>{Fmt.km(series.distance[series.distance.length - 1] ?? 0)} km</span>
              </div>
            </Card>
          ) : null}
        </>
      ) : null}
    </div>
  );
}

// MARK: - Devices

function DevicesSheet(props: { state: AppState; close: () => void }) {
  const { state } = props;
  const ble = state.ble;
  useEffect(() => {
    act("ble.scan", 60);
    return () => {
      act("ble.stopScan");
    };
  }, []);
  const hasClick = state.settings.assignedDevices.click != null || state.settings.assignedDevices.clickLeft != null;
  return (
    <Modal
      title="Geräte"
      close={props.close}
      width={600}
      footer={
        <>
          <Toggle label="Demo-Modus (ohne Hardware)" checked={ble.isDemo} onChange={(v) => act("ble.demo", v)} />
          <div class="grow" />
          <button class="start-button small" onClick={props.close}>
            Fertig
          </button>
        </>
      }
    >
      <div class="row">
        <h2>Geräte</h2>
        <div class="grow" />
        {ble.isScanning ? (
          <span class="row gap8 secondary">
            <Spinner /> Suche läuft…
          </span>
        ) : (
          <button class="button" disabled={ble.adapter !== "poweredOn"} onClick={() => act("ble.scan", 60)}>
            Erneut suchen
          </button>
        )}
      </div>
      <span class="secondary small">
        Wecke die Geräte auf: Kurbel drehen, Pulsgurt anlegen, Click-Taste drücken. Der Click v2 besteht aus zwei Geräten (rechts +, links −), beide werden einzeln gekoppelt. Kein Gerät ist
        Pflicht: Was fehlt, ersetzt die App so gut es geht.
      </span>
      {ble.adapter !== "poweredOn" ? (
        <span class="note warn small">
          <Icon name="warning" /> {ble.adapterMessage ?? "Bluetooth wird gestartet…"}
        </span>
      ) : null}
      {ble.visibleRoles.map((role) => {
        const status = ble.status[role];
        const assigned = state.settings.assignedDevices[role];
        const candidates = ble.discovered.filter((d) => d.roles.includes(role) && d.id !== assigned);
        return (
          <Card key={role} title={roleInfo[role].title}>
            <div class="row gap10">
              <div class="col">
                <span class="strong">{status.name ?? "Kein Gerät"}</span>
                <span class="secondary tiny">{status.detail ?? stateLabel(status)}</span>
              </div>
              <div class="grow" />
              {assigned ? (
                <button class="button" onClick={() => act("ble.unassign", role)}>
                  Entfernen
                </button>
              ) : null}
            </div>
            {candidates.map((d) => (
              <div key={d.id} class="row gap10">
                <span>{d.name}</span>
                <span class="secondary tiny">{d.rssi} dBm</span>
                <div class="grow" />
                <button class="button" onClick={() => act("ble.assign", d.id, role)}>
                  Verbinden
                </button>
              </div>
            ))}
          </Card>
        );
      })}
      {hasClick ? (
        <Card title="Click-Tasten">
          {ble.learningDirection ? (
            <span class="accent-soft strong">{ble.learningDirection === "up" ? "Drücke jetzt die Taste für SCHWERER." : "Drücke jetzt die Taste für LEICHTER."}</span>
          ) : (
            <span class="secondary small">
              {Object.keys(state.settings.clickButtonMap).length === 0
                ? "Standard: Click v1 wie beschriftet. Beim Click v2 schaltet die rechte Hälfte schwerer, die linke leichter. Hast du nur eine Hälfte, ordne zwei ihrer Tasten zu."
                : `Eigene Zuordnung aktiv (${Object.keys(state.settings.clickButtonMap).length} Tasten).`}
            </span>
          )}
          {ble.learnedSummary ? <span class="secondary tiny">{ble.learnedSummary}</span> : null}
          <div class="row gap8">
            {ble.learningDirection ? (
              <button class="button" onClick={() => act("ble.learnStop")}>
                Abbrechen
              </button>
            ) : (
              <>
                <button class="button" onClick={() => act("ble.learnStart")}>
                  Tasten zuordnen…
                </button>
                {Object.keys(state.settings.clickButtonMap).length > 0 ? (
                  <button class="button" onClick={() => act("ble.learnReset")}>
                    Standard
                  </button>
                ) : null}
              </>
            )}
          </div>
        </Card>
      ) : null}
    </Modal>
  );
}

// MARK: - Settings

function NumberField(props: { value: number; onChange: (v: number) => void; unit: string }) {
  const [text, setText] = useState(Fmt.decimal(props.value, props.value % 1 === 0 ? 0 : 1));
  const commit = () => {
    const v = Number(text.replace(",", "."));
    if (Number.isFinite(v) && v > 0) props.onChange(v);
    else setText(Fmt.decimal(props.value, props.value % 1 === 0 ? 0 : 1));
  };
  return (
    <span class="row gap6">
      <input class="input narrow" value={text} onInput={(e) => setText((e.currentTarget as HTMLInputElement).value)} onBlur={commit} onKeyDown={(e) => e.key === "Enter" && commit()} />
      <span class="secondary">{props.unit}</span>
    </span>
  );
}

function SettingsSheet(props: { state: AppState; close: () => void }) {
  const { state } = props;
  const s = state.settings;
  const [tab, setTab] = useState<"rider" | "trainer" | "intervals" | "display">("rider");
  const [apiKey, setApiKey] = useState("");
  const [testState, setTestState] = useState<string | null>(null);
  const [importState, setImportState] = useState<string | null>(null);
  const [shortcutState, setShortcutState] = useState<string | null>(null);

  const row = (label: any, control: any) => (
    <div class="form-row">
      <span>{label}</span>
      <div class="grow" />
      {control}
    </div>
  );

  let body;
  if (tab === "rider") {
    body = (
      <div class="form">
        <MetricLabel text="FAHRER" />
        {row("Gewicht", <NumberField value={s.riderWeight} unit="kg" onChange={(v) => set({ riderWeight: v })} />)}
        {row("Rad", <NumberField value={s.bikeWeight} unit="kg" onChange={(v) => set({ bikeWeight: v })} />)}
        {row(`FTP (manuell): ${s.ftp} W`, <Stepper value={s.ftp} min={80} max={500} step={5} onChange={(v) => set({ ftp: v })} />)}
        <Toggle label="FTP aus intervals.icu verwenden, wenn vorhanden" checked={s.useIntervalsFTP} onChange={(v) => set({ useIntervalsFTP: v })} />
        {state.intervals.athleteFTP != null ? <span class="secondary small">intervals.icu: {state.intervals.athleteFTP} W</span> : null}
      </div>
    );
  } else if (tab === "trainer") {
    body = (
      <div class="form">
        <MetricLabel text="ANTRIEB AM TRAINER" />
        {row(`Kettenblatt: ${s.chainring} Zähne`, <Stepper value={s.chainring} min={20} max={60} onChange={(v) => set({ chainring: v })} />)}
        {row(`Zwift Cog: ${s.cog} Zähne`, <Stepper value={s.cog} min={10} max={20} onChange={(v) => set({ cog: v })} />)}
        {s.measuredTrainerRatio > 0
          ? row(
              `Gemessene Übersetzung: ${Fmt.decimal(s.measuredTrainerRatio, 2)}`,
              <button class="button" onClick={() => set({ measuredTrainerRatio: 0 })}>
                Zurücksetzen
              </button>,
            )
          : <span class="secondary small">Die tatsächliche Übersetzung wird bei der ersten Fahrt automatisch gemessen.</span>}
        <MetricLabel text="SCHALTEN UND WIDERSTAND" />
        {row(`Startgang: ${s.startGear}`, <Stepper value={s.startGear} min={1} max={24} onChange={(v) => set({ startGear: v })} />)}
        <span>Trainer-Schwierigkeit: {Math.round(s.difficulty * 100)} %</span>
        <Slider value={s.difficulty} min={0} max={1} step={0.05} onInput={(v) => set({ difficulty: v })} />
        <span class="secondary tiny">Wie stark Steigungen am Trainer zu spüren sind. Zwift nutzt standardmäßig 50 %. Die angezeigte Geschwindigkeit rechnet immer mit der vollen Steigung.</span>
        <div class="row gap8">
          <span>Widerstand</span>
          <div class="grow" />
          {resistanceModes.map((m) => (
            <ChoiceChip key={m.id} title={m.title} selected={s.resistanceMode === m.id} onClick={() => set({ resistanceMode: m.id })} />
          ))}
        </div>
        <span class="secondary tiny">{resistanceModes.find((m) => m.id === s.resistanceMode)?.detail}</span>
      </div>
    );
  } else if (tab === "intervals") {
    const save = async () => {
      setTestState("Teste…");
      const key = apiKey;
      setApiKey("");
      setTestState(await act("intervals.saveKey", key));
    };
    body = (
      <div class="form">
        <MetricLabel text="ZUGANG" />
        {row(
          "Athleten-ID",
          <input class="input" value={s.intervalsAthleteId} placeholder="0 = eigenes Konto" onInput={(e) => set({ intervalsAthleteId: (e.currentTarget as HTMLInputElement).value })} />,
        )}
        {row(
          "API-Key",
          <input
            class="input"
            type="password"
            value={apiKey}
            placeholder={state.intervals.configured ? "gespeichert" : "aus Settings › Developer Settings"}
            onInput={(e) => setApiKey((e.currentTarget as HTMLInputElement).value)}
          />,
        )}
        <div class="row gap8">
          <button class="button" disabled={apiKey === "" && !state.intervals.configured} onClick={save}>
            Speichern und testen
          </button>
          {state.intervals.configured ? (
            <button
              class="button danger"
              onClick={() => {
                act("intervals.clearKey");
                setTestState(null);
              }}
            >
              Key löschen
            </button>
          ) : null}
          <div class="grow" />
          {testState ? <span class="secondary small">{testState}</span> : null}
        </div>
        <span class="secondary tiny">Der Key liegt verschlüsselt im Schlüsselbund des Systems (GNOME-Schlüsselbund bzw. KWallet).</span>
        <MetricLabel text="UPLOAD" />
        <Toggle label="Fahrten nach dem Ende automatisch hochladen" checked={s.autoUpload} onChange={(v) => set({ autoUpload: v })} />
        <span class="secondary tiny">
          Jede Fahrt wird zuerst auf dem Rechner gesichert. Fahrten ohne API-Key oder ohne Netz werden automatisch nachgeladen: beim Speichern des Keys, beim Start der App und wenn du zur App
          wechselst.
        </span>
        {state.pendingUploads > 0
          ? row(
              `${state.pendingUploads} Fahrt(en) warten auf den Upload`,
              <button class="button" disabled={!state.intervals.configured} onClick={() => act("rides.sync")}>
                Jetzt hochladen
              </button>,
            )
          : null}
        <div class="row gap8">
          <button
            class="button"
            onClick={async () => {
              setImportState("Lade hoch…");
              const failed = await act("rides.import");
              setImportState(failed == null ? null : failed === 0 ? "Übernommen" : `${failed} Datei(en) sind keine FIT-Dateien`);
            }}
          >
            FIT-Datei hochladen…
          </button>
          <button class="button" onClick={() => act("rides.openFolder")}>
            Gesicherte Fahrten zeigen
          </button>
          <div class="grow" />
          {importState ? <span class="secondary small">{importState}</span> : null}
        </div>
      </div>
    );
  } else {
    body = (
      <div class="form">
        <MetricLabel text="LEISTE" />
        <Toggle label="Steuerzeile mit Musik, Pause und Ziel" checked={s.showControlRow} onChange={(v) => set({ showControlRow: v })} />
        <span>Deckkraft: {Math.round(s.overlayOpacity * 100)} %</span>
        <Slider value={s.overlayOpacity} min={0.3} max={0.95} step={0.05} onInput={(v) => set({ overlayOpacity: v })} />
        <div class="row gap8">
          <span>Standardanzeige</span>
          <div class="grow" />
          <ChoiceChip title="Leiste" selected={s.defaultDisplay === "bar"} onClick={() => set({ defaultDisplay: "bar" })} />
          <ChoiceChip title="Vollbild" selected={s.defaultDisplay === "fullscreen"} onClick={() => set({ defaultDisplay: "fullscreen" })} />
        </div>
        <MetricLabel text="TASTENKÜRZEL" />
        <span class="secondary tiny">
          Strg+Alt+Bild↑/↓ schaltet, Strg+Alt+P pausiert, Strg+Alt+F wechselt Leiste und Vollbild. Unter Wayland erreichen die Kürzel die App nicht, solange ein anderes Programm im
          Vordergrund ist. Als GNOME-Kürzel eingerichtet funktionieren sie überall.
        </span>
        <div class="row gap8">
          <button class="button" onClick={async () => setShortcutState(await act("shortcuts.installGnome"))}>
            Als GNOME-Kürzel einrichten
          </button>
        </div>
        {shortcutState ? <span class="secondary small">{shortcutState}</span> : null}
        <MetricLabel text="TESTEN" />
        <Toggle label="Demo-Modus (Trainer, Puls und Kadenz simulieren)" checked={state.ble.isDemo} onChange={(v) => act("ble.demo", v)} />
        <span class="secondary tiny">Version {state.version}</span>
      </div>
    );
  }

  return (
    <Modal
      title="Einstellungen"
      close={props.close}
      width={600}
      footer={
        <>
          <div class="grow" />
          <button class="start-button small" onClick={props.close}>
            Fertig
          </button>
        </>
      }
    >
      <h2>Einstellungen</h2>
      <div class="segmented" role="tablist">
        {(
          [
            ["rider", "Fahrer"],
            ["trainer", "Trainer"],
            ["intervals", "intervals.icu"],
            ["display", "Anzeige"],
          ] as const
        ).map(([id, title]) => (
          <button key={id} role="tab" aria-selected={tab === id} aria-pressed={tab === id} onClick={() => setTab(id)}>
            {title}
          </button>
        ))}
      </div>
      {body}
    </Modal>
  );
}

// MARK: - Workout editor

function DurationField(props: { seconds: number; onChange: (s: number) => void }) {
  const [text, setText] = useState(formatDuration(props.seconds));
  const [focused, setFocused] = useState(false);
  useEffect(() => {
    if (!focused) setText(formatDuration(props.seconds));
  }, [props.seconds]);
  const commit = () => {
    const parsed = parseDuration(text);
    if (parsed != null) props.onChange(parsed);
    setText(formatDuration(parsed ?? props.seconds));
  };
  return (
    <span class="row gap4" title="Dauer als Minuten:Sekunden, z. B. 4:30, oder nur Minuten">
      <input
        class="input narrow right"
        value={text}
        onFocus={() => setFocused(true)}
        onInput={(e) => setText((e.currentTarget as HTMLInputElement).value)}
        onBlur={() => {
          setFocused(false);
          commit();
        }}
        onKeyDown={(e) => e.key === "Enter" && commit()}
        aria-label="Dauer"
      />
      <Stepper value={props.seconds} min={15} max={14_400} step={30} onChange={props.onChange} />
    </span>
  );
}

function PercentField(props: { percent: number; ftp: number; onChange: (p: number) => void }) {
  return (
    <span class="row gap4">
      <input
        class="input tiny-input right"
        value={props.percent}
        aria-label="Prozent FTP"
        onChange={(e) => {
          const v = Number((e.currentTarget as HTMLInputElement).value);
          if (Number.isFinite(v)) props.onChange(Math.min(300, Math.max(10, Math.round(v))));
        }}
      />
      <span>%</span>
      <Stepper value={props.percent} min={10} max={300} step={5} onChange={props.onChange} />
      <span class="secondary tiny" style={{ width: "42px" }}>
        {Math.round((props.percent / 100) * props.ftp)} W
      </span>
    </span>
  );
}

function WorkoutEditor(props: { state: AppState; initial: CustomWorkout; close: () => void; saved: (id: string) => void }) {
  const { state } = props;
  const [draft, setDraft] = useState<CustomWorkout>(props.initial);
  const [copied, setCopied] = useState(false);
  const ftp = state.intervals.effectiveFTP;
  const zones = zonesOf(state);
  const steps = Custom.steps(draft);
  const top = Math.max(1.2, Math.max(1, ...steps.map((x) => Math.max(x.startFraction ?? 0, x.endFraction ?? 0))) * 1.05);

  const update = (next: CustomWorkout) => {
    setDraft(next);
    setCopied(false);
  };
  const setBlocks = (blocks: WorkoutBlock[]) => update({ ...draft, blocks });

  /** Edits one block, top level or inside a repeat group. */
  const editList = (list: WorkoutBlock[], change: (list: WorkoutBlock[]) => WorkoutBlock[], parent: string | null): void => {
    if (parent == null) setBlocks(change(list));
    else setBlocks(draft.blocks.map((b) => (b.id === parent ? { ...b, children: change(b.children) } : b)));
  };

  const rowActions = (block: WorkoutBlock, list: WorkoutBlock[], parent: string | null) => {
    const i = list.findIndex((b) => b.id === block.id);
    const move = (offset: number) =>
      editList(
        list,
        (l) => {
          const copy = [...l];
          const j = i + offset;
          if (j < 0 || j >= copy.length) return copy;
          [copy[i], copy[j]] = [copy[j], copy[i]];
          return copy;
        },
        parent,
      );
    return (
      <Menu
        label="Aktionen"
        items={[
          i > 0 ? { title: "Nach oben", action: () => move(-1) } : null,
          i < list.length - 1 ? { title: "Nach unten", action: () => move(1) } : null,
          { title: "Duplizieren", action: () => editList(list, (l) => [...l.slice(0, i + 1), Block.copy(block), ...l.slice(i + 1)], parent) },
          { title: "Löschen", danger: true, action: () => editList(list, (l) => l.filter((b) => b.id !== block.id), parent) },
        ].filter((x) => x != null)}
      />
    );
  };

  const stepRow = (block: WorkoutBlock, list: WorkoutBlock[], parent: string | null) => {
    const patch = (p: Partial<WorkoutBlock>) => editList(list, (l) => l.map((b) => (b.id === block.id ? { ...b, ...p } : b)), parent);
    return (
      <div key={block.id} class="row gap10 step-row">
        <span class="step-color" style={{ background: block.kind === "free" ? "rgba(255,255,255,0.3)" : Theme.zoneColor(zones.indexForFraction(block.startPercent / 100)) }} />
        <select class="input" value={block.kind} onChange={(e) => patch({ kind: (e.currentTarget as HTMLSelectElement).value as BlockKind })} aria-label="Art">
          {(["steady", "ramp", "free"] as BlockKind[]).map((k) => (
            <option key={k} value={k}>
              {blockKindTitles[k]}
            </option>
          ))}
        </select>
        <DurationField seconds={block.duration} onChange={(duration) => patch({ duration: Math.max(15, duration) })} />
        {block.kind === "steady" ? (
          <PercentField percent={block.startPercent} ftp={ftp} onChange={(v) => patch({ startPercent: v, endPercent: v })} />
        ) : block.kind === "ramp" ? (
          <>
            <PercentField percent={block.startPercent} ftp={ftp} onChange={(v) => patch({ startPercent: v })} />
            <Icon name="arrowRight" color={Theme.secondary} />
            <PercentField percent={block.endPercent} ftp={ftp} onChange={(v) => patch({ endPercent: v })} />
          </>
        ) : (
          <span class="secondary tiny">ohne ERG, du schaltest selbst</span>
        )}
        <input class="input grow" value={block.label} placeholder="Bezeichnung" onInput={(e) => patch({ label: (e.currentTarget as HTMLInputElement).value })} />
        {rowActions(block, list, parent)}
      </div>
    );
  };

  const addBar = (list: WorkoutBlock[], parent: string | null) => {
    const add = (b: WorkoutBlock) => editList(list, (l) => [...l, b], parent);
    const nested = parent != null;
    const button = (title: string, make: () => WorkoutBlock) => (
      <button class="button small" onClick={() => add(make())}>
        {title}
      </button>
    );
    return (
      <div class="row gap6 wrap-row">
        <Icon name="plus" size={12} color={Theme.secondary} />
        {!nested ? button("Aufwärmen", () => Block.ramp(10, 45, 70, "Aufwärmen")) : null}
        {button("Konstant", () => Block.steady(5, nested ? 105 : 75))}
        {button("Rampe", () => Block.ramp(5, 60, 90))}
        {button("Erholung", () => Block.steady(3, 55, "Erholung"))}
        {button("Frei", () => Block.free(5))}
        {!nested ? button("Intervalle", () => Block.repeats(4, [Block.steady(4, 105, "Intervall"), Block.steady(3, 55, "Erholung")])) : null}
        {!nested ? button("Ausfahren", () => Block.ramp(8, 65, 45, "Ausfahren")) : null}
      </div>
    );
  };

  const stat = (label: string, value: string) => (
    <div class="col">
      <MetricLabel text={label} size={10} />
      <span class="num" style={{ fontSize: "17px", fontWeight: 700 }}>
        {value}
      </span>
    </div>
  );

  return (
    <Modal
      title="Workout bearbeiten"
      close={props.close}
      width={820}
      footer={
        <>
          <button
            class="button"
            title="Text für den Workout-Editor von intervals.icu"
            onClick={() => {
              act("clipboard.write", Custom.intervalsText(draft));
              setCopied(true);
            }}
          >
            <Icon name={copied ? "check" : "copy"} /> {copied ? "Kopiert" : "Als intervals.icu-Text kopieren"}
          </button>
          <div class="grow" />
          <button class="button" onClick={props.close}>
            Abbrechen
          </button>
          <button
            class="start-button small"
            disabled={!Custom.isValid(draft)}
            onClick={async () => {
              const id = await act("workouts.save", draft);
              if (id) props.saved(id);
            }}
          >
            Speichern
          </button>
        </>
      }
    >
      <div class="row gap10">
        <input class="input title-input grow" value={draft.name} placeholder="Name des Workouts" onInput={(e) => update({ ...draft, name: (e.currentTarget as HTMLInputElement).value })} />
        <select
          class="input"
          value=""
          aria-label="Vorlage"
          onChange={(e) => {
            const template = Custom.templates().find((t) => t.name === (e.currentTarget as HTMLSelectElement).value);
            if (template) update({ ...draft, blocks: template.blocks, name: draft.name === "" || draft.name === "Neues Workout" ? template.name : draft.name });
          }}
        >
          <option value="">Vorlage…</option>
          {Custom.templates().map((t) => (
            <option key={t.name} value={t.name}>
              {t.name}
            </option>
          ))}
        </select>
      </div>
      <input class="input plain" value={draft.notes} placeholder="Notiz (optional)" onInput={(e) => update({ ...draft, notes: (e.currentTarget as HTMLInputElement).value })} />
      <div class="editor-preview">
        <WorkoutChart steps={steps} elapsed={0} zones={zones} gap={1} minHeight={3} top={top} height={90} />
      </div>
      <div class="row gap18">
        {stat("DAUER", Fmt.clock(Custom.duration(draft), true))}
        {stat("TSS ≈", String(Custom.stressScore(draft)))}
        {stat("IF ≈", Fmt.decimal(Custom.intensityFactor(draft), 2))}
        {stat("ABSCHNITTE", String(steps.length))}
        <div class="grow" />
        <span class="secondary tiny">FTP {ftp} W</span>
      </div>
      <div class="col gap8 editor-list">
        {draft.blocks.map((block) =>
          block.kind === "repeats" ? (
            <div key={block.id} class="repeat-group col gap8">
              <div class="row gap10">
                <Icon name="repeat" color={Theme.accentSoft} />
                <span class="num" style={{ fontSize: "18px", fontWeight: 700 }}>
                  {block.reps} ×
                </span>
                <Stepper value={block.reps} min={1} max={30} onChange={(reps) => setBlocks(draft.blocks.map((b) => (b.id === block.id ? { ...b, reps } : b)))} />
                <span class="secondary tiny">= {Fmt.clock(Block.totalDuration(block), true)}</span>
                <div class="grow" />
                {rowActions(block, draft.blocks, null)}
              </div>
              {block.children.map((child) => stepRow(child, block.children, block.id))}
              {addBar(block.children, block.id)}
            </div>
          ) : (
            stepRow(block, draft.blocks, null)
          ),
        )}
        {draft.blocks.length === 0 ? <span class="secondary small center-text">Noch keine Abschnitte. Füge unten den ersten hinzu.</span> : null}
      </div>
      {addBar(draft.blocks, null)}
    </Modal>
  );
}
