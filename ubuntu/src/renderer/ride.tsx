// Floating bar (variant A of the design) and the full screen dashboard.
import { useRef } from "preact/hooks";
import { Fmt, PowerZones, Theme } from "../core/basics";
import { AppState, RideState, isUsable, stateLabel } from "../core/state";
import { deviceRoles, roleInfo } from "../core/ble";
import { ProfileBars, Scaled, WorkoutChart, ZoneSegments } from "./charts";
import { GearPill, GradeArrow, Icon, MetricLabel, act } from "./store";

export const OVERLAY = { baseWidth: 980, barHeight: 128, controlsHeight: 172 };

const num = (size: number, weight = 700) => ({ fontSize: `${size}px`, fontWeight: weight });

// MARK: Bar

/** Values on top, profile or workout below, optional control row. Designed at 980 px width. */
export function OverlayBar(props: { ride: RideState; state: AppState; opacity: number; controls: boolean; interactive: boolean }) {
  const { ride: r, state } = props;
  const zones = new PowerZones(r.zones);
  const height = props.controls ? OVERLAY.controlsHeight : OVERLAY.barHeight;
  const paused = { opacity: r.isPaused ? 0.45 : 1 };

  const value = (label: string, text: string) => (
    <div class="col">
      <MetricLabel text={label} />
      <div class="num" style={{ ...num(38), color: r.isPaused ? "rgba(255,255,255,0.45)" : "#fff" }}>
        {text}
      </div>
    </div>
  );

  const slotSix = () => {
    if (r.showsTestAverage) {
      return (
        <div class="col">
          <MetricLabel text="Ø TEST" />
          <div class="baseline">
            <span class="num" style={{ ...num(38), color: r.testAverage != null ? Theme.zoneColor(zones.index(r.testAverage, r.ftp)) : "#fff" }}>
              {r.testAverage ?? "–"}
            </span>
            <span class="unit">W</span>
          </div>
        </div>
      );
    }
    if (r.showsTarget) {
      return (
        <div class="col">
          <MetricLabel text="ZIEL" />
          <div class="baseline">
            <span class="num" style={{ ...num(38), color: r.targetColor }}>
              {r.targetText}
            </span>
            <span class="unit">W</span>
          </div>
        </div>
      );
    }
    return (
      <div class="col" style={paused}>
        <MetricLabel text="STEIGUNG" />
        <div class="row" style={{ gap: "6px" }}>
          <GradeArrow grade={r.gradePercent} width={14} color={r.gradeColor} />
          <div class="baseline" style={{ color: r.gradeColor }}>
            <span class="num" style={num(38)}>
              {r.gradeText}
            </span>
            <span style={{ fontSize: "14px", fontWeight: 600 }}>%</span>
          </div>
        </div>
      </div>
    );
  };

  const bottom = () => {
    if (r.bottom === "profile") {
      return (
        <div class="row bottom-row">
          <div class="grow">
            <ProfileBars columns={r.barColumns} marker={r.barMarker} height={28} />
          </div>
          <div class="baseline nowrap">
            <span class="num" style={num(22)}>
              {r.distanceValue}
            </span>
            <span class="label13">{r.distanceSuffix}</span>
          </div>
        </div>
      );
    }
    if (r.bottom === "workout") {
      return (
        <div class="row bottom-row">
          <div class="grow">
            <WorkoutChart steps={r.chartSteps} elapsed={r.movingTime} zones={zones} top={r.chartTop} height={28} />
          </div>
          <div class="baseline nowrap">
            <span class="num" style={num(22)}>
              {r.stepLeftText}
            </span>
            <span class="label13" style={{ color: r.hasTestResult ? Theme.accentSoft : undefined }}>
              {r.workoutRightText}
            </span>
          </div>
        </div>
      );
    }
    return (
      <div class="row bottom-row" style={{ gap: "12px", alignItems: "center" }}>
        <Icon name="pause" size={16} color={Theme.accent} />
        <span style={{ fontSize: "15px", fontWeight: 700, letterSpacing: "0.6px" }}>PAUSIERT</span>
        <span class="nowrap" style={{ fontSize: "14px", fontWeight: 500, color: Theme.label }}>
          {r.pauseHint}
        </span>
        <div class="grow">
          {r.usesCourse ? (
            <ProfileBars columns={r.barColumns} marker={r.barMarker} dimAll height={28} />
          ) : (
            <WorkoutChart steps={r.workoutSteps} elapsed={r.movingTime} zones={zones} height={28} opacity={0.4} />
          )}
        </div>
        <span class="label13 nowrap">
          {r.distanceValue} {r.distanceSuffix}
        </span>
      </div>
    );
  };

  return (
    <div class="bar" style={{ width: `${OVERLAY.baseWidth}px`, height: `${height}px`, background: `rgba(14,16,22,${props.opacity})` }}>
      <div class="row top-row">
        <div class="watt-group" aria-label={`${r.watts} Watt, ${r.chipText}`}>
          <div class="col">
            <MetricLabel text="WATT · 3 S" />
            <div class="baseline">
              <span class="num" style={{ ...num(46, 800), color: r.wattColor }}>
                {r.watts}
              </span>
              <span class="unit">W</span>
            </div>
          </div>
          <div class="col" style={{ gap: "6px", alignSelf: "flex-end", paddingBottom: "8px" }}>
            <span class="zone-chip" style={{ background: r.isPaused ? "rgba(255,255,255,0.4)" : r.wattColor }}>
              {r.chipText}
            </span>
            <ZoneSegments active={r.isPaused ? null : r.zoneIndex} width={9} height={4} spacing={3} />
          </div>
        </div>
        {value("RPM", r.rpmText)}
        {value("KM/H", r.kmhText)}
        <div class="col">
          <MetricLabel text="PULS" />
          <div class="row" style={{ gap: "6px" }}>
            <Icon name="heart" size={17} color={Theme.heart} />
            <span class="num" style={{ ...num(38), color: r.isPaused ? "rgba(255,255,255,0.45)" : "#fff" }}>
              {r.heartText}
            </span>
          </div>
        </div>
        <div class="col" style={{ ...paused, gap: "4px" }}>
          <MetricLabel text={r.showsErgOffset ? "ERG" : "GANG"} />
          {r.showsErgOffset ? <GearPill main={r.ergOffsetText} suffix="W" size={30} trigger={r.shiftCount} /> : <GearPill main={String(r.gear)} suffix="/24" size={30} trigger={r.shiftCount} />}
        </div>
        <div style={{ width: "118px" }}>{slotSix()}</div>
        <div class="col" style={{ alignItems: "flex-end" }}>
          <MetricLabel text="ZEIT" />
          <span class="num" style={num(38)}>
            {r.timeText}
          </span>
        </div>
      </div>
      {bottom()}
      {props.controls ? <ControlRow ride={r} state={state} interactive={props.interactive} /> : null}
    </div>
  );
}

function RoundButton(props: { icon: string; label: string; size?: number; filled?: boolean; onClick: () => void }) {
  const size = props.size ?? 28;
  return (
    <button
      class={props.filled ? "round filled" : "round"}
      style={{ width: `${size}px`, height: `${size}px` }}
      title={props.label}
      aria-label={props.label}
      onClick={props.onClick}
    >
      <Icon name={props.icon} size={(13 * size) / 28} />
    </button>
  );
}

/** Third row of the bar: music on the left, ride controls on the right. */
function ControlRow(props: { ride: RideState; state: AppState; interactive: boolean }) {
  const { ride: r, state } = props;
  const music = state.music;
  const clickConnected = isUsable(state.ble.status.click) || isUsable(state.ble.status.clickLeft);
  const offset = r.clickAdjustsErgOffset;
  return (
    <div class="row control-row" data-interactive>
      {!music.installed && !music.running ? (
        <span />
      ) : music.running ? (
        <div class="row music">
          <span class="music-art">
            {music.track?.artworkURL ? <img src={music.track.artworkURL} alt="" /> : <Icon name="music" size={14} color={Theme.accent} />}
          </span>
          <div class="col music-text">
            <span class="ellipsis" style={{ fontSize: "13px", fontWeight: 600 }}>
              {music.track?.name ?? "Spotify"}
            </span>
            <span class="ellipsis" style={{ fontSize: "11px", fontWeight: 500, color: Theme.label }}>
              {music.track?.artist ?? (music.playing ? "" : "Pausiert")}
            </span>
          </div>
          <div class="row" style={{ gap: "4px" }}>
            <RoundButton icon="previous" label="Vorheriger Titel" size={26} onClick={() => act("music.previous")} />
            <RoundButton icon={music.playing ? "pause" : "play"} label={music.playing ? "Musik pausieren" : "Musik abspielen"} filled onClick={() => act("music.playPause")} />
            <RoundButton icon="next" label="Nächster Titel" size={26} onClick={() => act("music.next")} />
          </div>
        </div>
      ) : (
        <button class="pill-button" onClick={() => act("music.launch")}>
          <Icon name="music" size={14} /> Spotify starten
        </button>
      )}
      <div class="grow" />
      {r.canEndTestEffort ? (
        <button class="pill-button prominent" onClick={() => act("ride.endTestEffort")} title="Rampe beenden, wenn du nicht mehr kannst">
          <Icon name="flag" size={14} /> Test beenden
        </button>
      ) : (
        <button class={r.phase === "paused" ? "pill-button prominent" : "pill-button"} onClick={() => act("ride.togglePause")} title="Pause / weiter (beide Click-Tasten oder Strg+Alt+P)">
          <Icon name={r.phase === "paused" ? "play" : "pause"} size={14} /> {r.phase === "paused" ? "Weiter" : "Pause"}
        </button>
      )}
      {!clickConnected ? (
        <div class="row stepper-capsule" title="Kein Click verbunden: hier oder mit Strg+Alt+Bild↑/↓ schalten">
          <RoundButton icon="minus" label={offset ? "5 W weniger" : "Leichter schalten"} size={24} onClick={() => act("ride.shift", "down")} />
          <div class="col center" style={{ minWidth: "40px" }}>
            <span class="tiny-label">{offset ? "ERG" : "GANG"}</span>
            <span class="num" style={num(15)}>
              {offset ? r.ergOffsetText : r.gear}
            </span>
          </div>
          <RoundButton icon="plus" label={offset ? "5 W mehr" : "Schwerer schalten"} size={24} onClick={() => act("ride.shift", "up")} />
        </div>
      ) : null}
      {r.canChangeGoal ? (
        <div class="row stepper-capsule">
          <RoundButton icon="minus" label="Ziel verkürzen" size={24} onClick={() => act("ride.adjustGoal", -1)} />
          <div class="col center" style={{ minWidth: "52px" }}>
            <span class="tiny-label">ZIEL</span>
            <span class="num" style={num(15)}>
              {r.goalLabel}
            </span>
          </div>
          <RoundButton icon="plus" label="Ziel verlängern" size={24} onClick={() => act("ride.adjustGoal", 1)} />
        </div>
      ) : null}
      <RoundButton icon="expand" label="Vollbild" onClick={() => act("display.toggle")} />
      <span style={{ width: "16px" }} />
    </div>
  );
}

/** The floating window: scales the bar to the window width, moves on drag, resizes at the corner. */
export function OverlayView(props: { state: AppState; ride: RideState | null }) {
  const { state, ride } = props;
  const drag = useRef<{ x: number; y: number; mode: "move" | "resize"; moved: boolean } | null>(null);
  if (!ride) return <div />;
  const controls = state.settings.showControlRow;
  const scale = window.innerWidth / OVERLAY.baseWidth;

  const onPointerDown = (e: PointerEvent) => {
    const target = e.target as HTMLElement;
    if (target.closest("button")) return;
    const mode = target.closest(".resize-grip") ? "resize" : "move";
    drag.current = { x: e.screenX, y: e.screenY, mode, moved: false };
    (e.currentTarget as HTMLElement).setPointerCapture(e.pointerId);
    act("overlay.dragStart");
  };
  const onPointerMove = (e: PointerEvent) => {
    const d = drag.current;
    if (!d) return;
    const dx = e.screenX - d.x;
    const dy = e.screenY - d.y;
    if (Math.abs(dx) + Math.abs(dy) > 2) d.moved = true;
    act(d.mode === "move" ? "overlay.dragMove" : "overlay.resize", dx, dy);
  };
  const onPointerUp = () => {
    if (drag.current) act("overlay.dragEnd");
    drag.current = null;
  };

  return (
    <div
      class="overlay-root"
      onPointerDown={onPointerDown}
      onPointerMove={onPointerMove}
      onPointerUp={onPointerUp}
      onDblClick={(e) => {
        if (!(e.target as HTMLElement).closest("button")) act("display.toggle");
      }}
    >
      <Scaled width={OVERLAY.baseWidth} height={controls ? OVERLAY.controlsHeight : OVERLAY.barHeight} scale={scale}>
        <OverlayBar ride={ride} state={state} opacity={state.settings.overlayOpacity} controls={controls} interactive />
      </Scaled>
      <div class="resize-grip" title="Größe ändern" />
    </div>
  );
}

// MARK: Full screen

export function DeviceDots(props: { state: AppState; size?: number }) {
  const size = props.size ?? 13;
  return (
    <div class="row" style={{ gap: `${size * 1.5}px` }}>
      {deviceRoles.map((role) => {
        const status = props.state.ble.status[role];
        if (status.state === "notAssigned") return null;
        const color = isUsable(status) ? Theme.ok : Theme.warn;
        return (
          <div key={role} class="row" style={{ gap: `${size * 0.6}px` }} title={`${roleInfo[role].title}: ${stateLabel(status)}`}>
            <span class="dot" style={{ width: `${size * 0.62}px`, height: `${size * 0.62}px`, background: color, boxShadow: `0 0 0 ${size * 0.23}px ${color}33` }} />
            <span style={{ fontSize: `${size}px`, fontWeight: 600, letterSpacing: `${size * 0.06}px`, color: Theme.secondary }}>{roleInfo[role].shortLabel}</span>
          </div>
        );
      })}
    </div>
  );
}

function FsChip(props: { text: string; color: string; background: string }) {
  return (
    <span class="fs-chip" style={{ color: props.color, background: props.background }}>
      {props.text}
    </span>
  );
}

function Tile(props: { label: string; children: any }) {
  return (
    <div class="tile">
      <MetricLabel text={props.label} size={13} />
      <div class="grow" />
      {props.children}
    </div>
  );
}

function Big(props: { text: string; unit?: string | null; color?: string; size?: number }) {
  return (
    <div class="baseline nowrap">
      <span class="num" style={{ ...num(props.size ?? 64), color: props.color ?? "#fff" }}>
        {props.text}
      </span>
      {props.unit ? <span style={{ fontSize: "16px", color: Theme.label, marginLeft: "6px" }}>{props.unit}</span> : null}
    </div>
  );
}

/** Designed at 1440 × 900 and scaled to the window. */
export function FullscreenRide(props: { ride: RideState; state: AppState }) {
  const { ride: r, state } = props;
  const zones = new PowerZones(r.zones);
  const valueColor = r.isPaused ? "rgba(255,255,255,0.45)" : "#fff";
  const gear = (size: number) =>
    r.showsErgOffset ? <GearPill main={r.ergOffsetText} suffix="W" size={size} trigger={r.shiftCount} /> : <GearPill main={String(r.gear)} suffix="/24" size={size} trigger={r.shiftCount} />;
  const heart = (unit: string | null) => (
    <div class="row" style={{ gap: "10px" }}>
      <Icon name="heart" size={28} color={Theme.heart} />
      <Big text={r.heartText} unit={unit} color={valueColor} />
    </div>
  );
  const grade = (
    <div class="row" style={{ gap: "10px" }}>
      <GradeArrow grade={r.gradePercent} width={24} color={r.gradeColor} />
      <div class="baseline" style={{ color: r.gradeColor }}>
        <span class="num" style={num(64)}>
          {r.gradeText}
        </span>
        <span style={{ fontSize: "20px", fontWeight: 600 }}>%</span>
      </div>
    </div>
  );
  const bigWatts = (
    <div class="baseline">
      <span class="num" style={{ ...num(196, 800), color: r.wattColor, lineHeight: "168px" }}>
        {r.watts}
      </span>
      <span style={{ fontSize: "36px", color: Theme.label, marginLeft: "10px" }}>W</span>
    </div>
  );

  const header = (
    <div class="row fs-header">
      {r.isTest ? (
        <>
          <FsChip text="FTP-TEST" color={Theme.onAccent} background={Theme.accent} />
          <span class="fs-title">{r.testTitle}</span>
          {r.testInfo ? <span style={{ fontSize: "16px", fontWeight: 600, color: r.hasTestResult ? Theme.accentSoft : Theme.secondary }}>{r.testInfo}</span> : null}
        </>
      ) : r.isWorkout ? (
        <>
          <FsChip text="WORKOUT" color={Theme.intervals} background={Theme.chip} />
          <span class="fs-title ellipsis">{r.name}</span>
          <FsChip text={r.workoutModeTitle.toUpperCase()} color={Theme.accentSoft} background="rgba(255,107,26,0.16)" />
        </>
      ) : (
        <>
          <FsChip text={r.isPaused ? "PAUSE" : "FREIE FAHRT"} color={Theme.accentSoft} background={Theme.chip} />
          <span class="fs-title">{r.courseTitle}</span>
          {r.goal.kind === "distance" ? <span style={{ fontSize: "16px", fontWeight: 500, color: Theme.secondary }}>{Fmt.km(r.goal.meters)} km</span> : null}
        </>
      )}
      <div class="grow" />
      <DeviceDots state={state} />
    </div>
  );

  const rideHero = (
    <div class="row fs-hero">
      <div class="col" style={{ width: "500px", gap: "14px" }}>
        <MetricLabel text="WATT · 3 S" size={14} />
        {bigWatts}
        <ZoneSegments active={r.isPaused ? null : r.zoneIndex} width={64} height={10} spacing={6} />
        <span style={{ fontSize: "18px", fontWeight: 600, color: r.isPaused ? Theme.secondary : Theme.zoneColor(r.zoneIndex) }}>{r.zoneLine}</span>
      </div>
      <div class="fs-grid three">
        <Tile label="TRITTFREQUENZ">
          <Big text={r.rpmText} unit="rpm" color={valueColor} />
        </Tile>
        <Tile label="GESCHWINDIGKEIT">
          <Big text={r.kmhText} unit="km/h" color={valueColor} />
        </Tile>
        <Tile label="PULS">{heart("bpm")}</Tile>
        <Tile label="GANG">{gear(56)}</Tile>
        <Tile label="STEIGUNG">{grade}</Tile>
        <Tile label="ZEIT">
          <Big text={r.timeText} color={valueColor} />
        </Tile>
      </div>
    </div>
  );

  const workoutHero = (
    <div class="row fs-hero">
      <div class="col" style={{ width: "470px", gap: "14px" }}>
        <MetricLabel text="WATT · 3 S" size={14} />
        {bigWatts}
        <div class="row" style={{ gap: "14px" }}>
          {r.compliance ? (
            <>
              <span class="zone-chip big" style={{ background: Theme.complianceColor(r.compliance) }}>
                {r.complianceText}
              </span>
              <span style={{ fontSize: "22px", fontWeight: 700, color: r.targetColor }}>Ziel {r.targetText} W</span>
              {r.workoutMode === "ergOffset" && r.ergOffset !== 0 ? <span style={{ fontSize: "15px", color: Theme.secondary }}>{r.ergOffsetText} W</span> : null}
            </>
          ) : (
            <span style={{ fontSize: "22px", fontWeight: 700, color: Theme.secondary }}>Freie Fahrt</span>
          )}
        </div>
      </div>
      <div class="col" style={{ width: "380px", gap: "14px" }}>
        <MetricLabel text={r.intervalLabel} size={14} />
        <span class="num" style={{ ...num(150, 800), lineHeight: "132px" }}>
          {r.stepLeftText}
        </span>
        <div class="progress" style={{ height: "10px" }}>
          <span style={{ width: `${Math.min(100, r.stepProgress * 100)}%`, background: r.stepColor }} />
        </div>
        <span class="ellipsis" style={{ fontSize: "16px", fontWeight: 500, color: Theme.secondary }}>
          {r.stepDescription}
        </span>
      </div>
      <div class="fs-grid two">
        <Tile label="RPM">
          <Big text={r.rpmText} color={valueColor} />
        </Tile>
        <Tile label="PULS">{heart(null)}</Tile>
        {r.isTest ? (
          <Tile label={r.hasTestResult ? "NEUE FTP" : "FTP ≈"}>
            <Big text={r.testEstimate != null ? String(r.testEstimate) : "–"} unit="W" color={Theme.accent} size={56} />
          </Tile>
        ) : r.usesCourse ? (
          <Tile label="STEIGUNG">{grade}</Tile>
        ) : (
          <Tile label="KM/H">
            <Big text={r.kmhText} color={valueColor} />
          </Tile>
        )}
        <Tile label={r.showsErgOffset ? "ERG-OFFSET" : "GANG"}>{gear(44)}</Tile>
      </div>
    </div>
  );

  const axis = (labels: string[]) => (
    <div class="row fs-axis">
      {labels.map((l, i) => (
        <span key={i}>{l}</span>
      ))}
    </div>
  );

  const profileSection = () => {
    const [start, end] = r.fullWindow;
    const labels = [0, 1, 2, 3, 4, 5, 6].map((i) => {
      const km = (start + ((end - start) * i) / 6) / 1000;
      const text = Math.round(km) === km ? String(km) : Fmt.decimal(km, 1);
      return i === 0 || i === 6 ? `${text} km` : text;
    });
    const x = Math.min(1, Math.max(0, r.fullMarker));
    return (
      <div class="col" style={{ gap: "14px" }}>
        <div class="row">
          <div class="row" style={{ gap: "18px" }}>
            <MetricLabel text="HÖHENPROFIL" size={13} />
            <span style={{ fontSize: "16px", fontWeight: 600 }}>↑ {Math.round(r.ascent)} hm</span>
            <span style={{ fontSize: "16px", fontWeight: 500 }}>
              <span style={{ color: Theme.secondary }}>Nächster Kilometer Ø </span>
              <b style={{ color: Theme.gradeColor(r.nextKilometerGrade) }}>{Fmt.signedGrade(r.nextKilometerGrade)} %</b>
            </span>
          </div>
          <div class="grow" />
          <div class="row" style={{ gap: "18px" }}>
            {Theme.gradeLegend().map((item) => (
              <span key={item.label} class="row" style={{ gap: "7px", fontSize: "13px", color: Theme.secondary }}>
                <span style={{ width: "10px", height: "10px", borderRadius: "3px", background: item.color }} />
                {item.label}
              </span>
            ))}
          </div>
        </div>
        <div class="chart-box" style={{ height: "236px" }}>
          <div style={{ position: "absolute", left: 0, right: 0, bottom: 0 }}>
            <ProfileBars columns={r.fullColumns} marker={r.fullMarker} spacing={1} minHeight={14} highlightCurrent={false} height={186} />
          </div>
          <span class="marker-line" style={{ left: `${x * 100}%` }} />
          <span class="marker-bubble" style={{ left: `clamp(70px, ${x * 100}%, calc(100% - 70px))` }}>
            {Fmt.km(r.distance)} km · {Math.round(r.altitude)} m
          </span>
        </div>
        {axis(labels)}
      </div>
    );
  };

  const workoutSection = () => {
    const minutes = r.chartDuration / 60;
    const labels = [0, 1, 2, 3, 4, 5, 6].map((i) => {
      const m = Math.round((minutes * i) / 6);
      return i === 0 || i === 6 ? `${m} min` : String(m);
    });
    const x = Math.min(1, r.movingTime / Math.max(1, r.chartDuration));
    const ftpY = 8 + ((236 - 8) * 1) / r.chartTop;
    return (
      <div class="col" style={{ gap: "14px" }}>
        <div class="row">
          <div class="row" style={{ gap: "18px" }}>
            <MetricLabel text={r.isTest ? "TEST" : "WORKOUT"} size={13} />
            <span style={{ fontSize: "16px", fontWeight: 600 }}>
              {r.isOpenRamp ? Fmt.clock(r.movingTime, false) : `${Fmt.clock(r.movingTime, false)} / ${Fmt.clock(r.playerDuration, false)}`}
            </span>
          </div>
          <div class="grow" />
          {r.nextStep ? (
            <div class="row" style={{ gap: "10px" }}>
              <MetricLabel text="DANACH" size={13} />
              <span style={{ width: "10px", height: "10px", borderRadius: "3px", background: r.nextStep.color }} />
              <span style={{ fontSize: "16px", fontWeight: 700 }}>{r.nextStep.text}</span>
            </div>
          ) : null}
        </div>
        <div class="chart-box" style={{ height: "236px" }}>
          <WorkoutChart
            steps={r.chartSteps}
            elapsed={r.movingTime}
            zones={zones}
            gap={3}
            minHeight={8}
            top={r.chartTop}
            inBlockMarker={false}
            trace={r.powerTrace}
            ftp={r.ftp}
            ftpLine
            height={236}
          />
          <span class="marker-line" style={{ left: `${x * 100}%` }} />
          <span class="marker-bubble" style={{ left: `clamp(40px, ${x * 100}%, calc(100% - 40px))` }}>
            {Fmt.clock(r.movingTime, false)}
          </span>
          <span class="ftp-label" style={{ bottom: `${ftpY + 6}px` }}>
            FTP {r.ftp} W
          </span>
        </div>
        {axis(labels)}
      </div>
    );
  };

  return (
    <div class="fullscreen" style={{ width: "1440px", height: "900px" }}>
      {header}
      <div class="grow" />
      {r.isWorkout ? workoutHero : rideHero}
      <div class="grow" />
      {r.isWorkout ? workoutSection() : profileSection()}
      <div class="grow" />
      <div class="row" style={{ gap: "20px", height: "36px" }}>
        <span class="num nowrap" style={num(28)}>
          {r.footerLeft}
        </span>
        <div class="progress grow" style={{ height: "10px" }}>
          <span style={{ width: `${r.progress * 100}%`, background: Theme.accent }} />
        </div>
        <span class="nowrap" style={{ fontSize: "18px", color: Theme.secondary }}>
          {r.footerRight}
        </span>
      </div>
    </div>
  );
}

export function FullscreenView(props: { state: AppState; ride: RideState | null }) {
  const scale = Math.min(window.innerWidth / 1440, window.innerHeight / 900);
  const onKey = (e: KeyboardEvent) => {
    if (e.ctrlKey || e.altKey || e.metaKey) return;
    if (["ArrowUp", "+", "="].includes(e.key)) act("ride.shift", "up");
    else if (["ArrowDown", "-"].includes(e.key)) act("ride.shift", "down");
    else if (e.key === " ") act("ride.togglePause");
    else if (e.key === "Escape") act("display.set", "bar");
    else return;
    e.preventDefault();
  };
  return (
    <div class="fullscreen-root" tabIndex={0} ref={(el) => el?.focus()} onKeyDown={onKey} onDblClick={() => act("display.set", "bar")}>
      {props.ride ? (
        <Scaled width={1440} height={900} scale={scale}>
          <FullscreenRide ride={props.ride} state={props.state} />
        </Scaled>
      ) : null}
    </div>
  );
}
