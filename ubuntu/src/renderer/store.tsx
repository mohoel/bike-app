// Connection to the main process and small shared UI pieces.
import { ComponentChildren } from "preact";
import { useEffect, useState } from "preact/hooks";
import { PowerZones } from "../core/basics";
import { RideEntry } from "../core/ride";
import { AppState, RideState } from "../core/state";

interface Bridge {
  init(): Promise<{ state: AppState; ride: RideState | null; history: RideEntry[] }>;
  action(name: string, ...args: unknown[]): Promise<any>;
  on(channel: "state" | "ride" | "history" | "nav", listener: (payload: any) => void): () => void;
}

const bridge = (window as unknown as { bike: Bridge }).bike;

export function act(name: string, ...args: unknown[]): Promise<any> {
  return bridge.action(name, ...args).catch((error) => {
    console.error(`Aktion ${name}:`, error);
    return null;
  });
}

export interface Snapshot {
  state: AppState | null;
  ride: RideState | null;
  history: RideEntry[];
}

let snapshot: Snapshot = { state: null, ride: null, history: [] };
const listeners = new Set<() => void>();
const navListeners = new Set<(target: string) => void>();

function update(patch: Partial<Snapshot>) {
  snapshot = { ...snapshot, ...patch };
  listeners.forEach((l) => l());
}

export function connect(): void {
  bridge.on("state", (state) => update({ state }));
  bridge.on("ride", (ride) => update({ ride }));
  bridge.on("history", (history) => update({ history }));
  bridge.on("nav", (target) => navListeners.forEach((l) => l(target)));
  void bridge.init().then((initial) => update(initial));
}

export function useSnapshot(): Snapshot {
  const [, setTick] = useState(0);
  useEffect(() => {
    const listener = () => setTick((t) => t + 1);
    listeners.add(listener);
    // The first data may have arrived before this listener existed.
    listener();
    return () => {
      listeners.delete(listener);
    };
  }, []);
  return snapshot;
}

export function useNav(handler: (target: string) => void): void {
  useEffect(() => {
    navListeners.add(handler);
    return () => {
      navListeners.delete(handler);
    };
  }, []);
}

export function useWindowSize(): { width: number; height: number } {
  const [size, setSize] = useState({ width: window.innerWidth, height: window.innerHeight });
  useEffect(() => {
    const onResize = () => setSize({ width: window.innerWidth, height: window.innerHeight });
    window.addEventListener("resize", onResize);
    return () => window.removeEventListener("resize", onResize);
  }, []);
  return size;
}

export const zonesOfState = (bounds: number[]) => new PowerZones(bounds);

// MARK: Icons (simple shapes, drawn in the current colour)

const paths: Record<string, string> = {
  pause: "M6 4h4v16H6zM14 4h4v16h-4z",
  play: "M7 4l13 8-13 8z",
  plus: "M11 4h2v7h7v2h-7v7h-2v-7H4v-2h7z",
  minus: "M4 11h16v2H4z",
  previous: "M11 12l9-7v14zM2 12l9-7v14z",
  next: "M13 12L4 5v14zM22 12l-9-7v14z",
  expand: "M4 4h7v2H7.4l4.3 4.3-1.4 1.4L6 7.4V11H4zM20 20h-7v-2h3.6l-4.3-4.3 1.4-1.4L18 16.6V13h2z",
  heart: "M12 21s-7.5-4.6-9.6-9.4C.9 8 2.9 4.5 6.5 4.5c2 0 3.6 1 4.5 2.6h2c.9-1.6 2.500-2.600 4.500-2.600 3.600 0 5.600 3.500 4.100 7.100C19.500 16.400 12 21 12 21zm0-2.400c2-1.300 6.100-4.500 7.500-7.700.900-2.200-.300-4.400-2.500-4.400-1.500 0-2.700.900-3.300 2.400h-3.400C9.700 7.400 8.500 6.500 7 6.500c-2.200 0-3.400 2.200-2.500 4.400 1.400 3.200 5.500 6.400 7.500 7.700z",
  music: "M9 4v11.200A3.500 3.500 0 1 0 11 18.500V8h6V4z",
  gear: "M12 8.500a3.500 3.500 0 1 0 0 7 3.500 3.500 0 0 0 0-7zm9 4.700v-2.400l-2.300-.500a7 7 0 0 0-.700-1.700l1.300-2-1.700-1.700-2 1.300a7 7 0 0 0-1.700-.700L13.200 3h-2.400l-.500 2.300a7 7 0 0 0-1.700.700l-2-1.300-1.700 1.700 1.300 2a7 7 0 0 0-.700 1.700L3 10.800v2.400l2.300.500c.200.600.400 1.200.700 1.700l-1.300 2 1.700 1.700 2-1.300c.500.300 1.100.500 1.700.700l.500 2.300h2.400l.500-2.300a7 7 0 0 0 1.700-.700l2 1.300 1.700-1.700-1.300-2c.300-.500.500-1.100.700-1.700z",
  chevronLeft: "M15 4l-8 8 8 8 1.500-1.500L10 12l6.500-6.500z",
  chevronRight: "M9 4l8 8-8 8-1.500-1.500L14 12 7.500 5.500z",
  check: "M9.500 16.200L5 11.700l-1.500 1.500 6 6L21 7.700l-1.500-1.500z",
  warning: "M12 3L1.500 21h21zm-1 6h2v6h-2zm0 8h2v2h-2z",
  clock: "M12 3a9 9 0 1 0 0 18 9 9 0 0 0 0-18zm0 2a7 7 0 1 1 0 14 7 7 0 0 1 0-14zm-1 2v6l4.500 2.700 1-1.700-3.500-2V7z",
  dots: "M5 10.500a1.500 1.500 0 1 0 0 3 1.500 1.500 0 0 0 0-3zm7 0a1.500 1.500 0 1 0 0 3 1.500 1.500 0 0 0 0-3zm7 0a1.500 1.500 0 1 0 0 3 1.500 1.500 0 0 0 0-3z",
  refresh: "M12 5V2L7.500 6 12 10V7a5 5 0 1 1-5 5H5a7 7 0 1 0 7-7z",
  flag: "M5 3h2v18H5zM8 4h11l-2.500 4.500L19 13H8z",
  repeat: "M7 7h10v3l4-4-4-4v3H5v6h2zM17 17H7v-3l-4 4 4 4v-3h12v-6h-2z",
  bike: "M5.500 11a4.500 4.500 0 1 0 0 9 4.500 4.500 0 0 0 0-9zm13 0a4.500 4.500 0 1 0 0 9 4.500 4.500 0 0 0 0-9zM14 5h3.500l1.800 6.200-1.900.600L16.300 8H14.800l-3 4.500H8.200L5.900 16l-1.700-1.100L7.800 9.500h5.500L12.300 7H10V5z",
  dice: "M5 3h14a2 2 0 0 1 2 2v14a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2zm3 3.500A1.500 1.500 0 1 0 8 9.500 1.500 1.500 0 0 0 8 6.500zm8 0a1.500 1.500 0 1 0 0 3 1.500 1.500 0 0 0 0-3zm-4 4a1.500 1.500 0 1 0 0 3 1.500 1.500 0 0 0 0-3zm-4 4a1.500 1.500 0 1 0 0 3 1.500 1.500 0 0 0 0-3zm8 0a1.500 1.500 0 1 0 0 3 1.500 1.500 0 0 0 0-3z",
  download: "M11 3h2v9l3.500-3.500L18 10l-6 6-6-6 1.500-1.500L11 12zM4 18h16v2H4z",
  copy: "M8 3h11a2 2 0 0 1 2 2v12h-2V5H8zM5 7h10a2 2 0 0 1 2 2v10a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V9a2 2 0 0 1 2-2z",
  arrowRight: "M13 5l7 7-7 7-1.500-1.500L16 13H4v-2h12l-4.500-4.500z",
  wand: "M4 20L16 8l-2-2L2 18zM18 2l.900 2.100L21 5l-2.100.900L18 8l-.900-2.100L15 5l2.100-.900zM20 12l.600 1.400L22 14l-1.400.600L20 16l-.600-1.400L18 14l1.400-.600z",
  info: "M12 3a9 9 0 1 0 0 18 9 9 0 0 0 0-18zm-1 7h2v7h-2zm0-3h2v2h-2z",
  undo: "M9 6V3L3 8l6 5v-3h5a4 4 0 0 1 0 8H8v2h6a6 6 0 0 0 0-12z",
};

export function Icon(props: { name: keyof typeof paths | string; size?: number; color?: string }) {
  const size = props.size ?? 16;
  return (
    <svg class="icon" width={size} height={size} viewBox="0 0 24 24" fill={props.color ?? "currentColor"} aria-hidden="true">
      <path d={paths[props.name] ?? ""} fill-rule="evenodd" clip-rule="evenodd" />
    </svg>
  );
}

/** Small uppercase label above a value. */
export function MetricLabel(props: { text: string; size?: number }) {
  const size = props.size ?? 11;
  return (
    <div class="metric-label" style={{ fontSize: `${size}px`, letterSpacing: `${size * 0.08}px` }}>
      {props.text}
    </div>
  );
}

/** Orange pill showing the gear (or ERG offset); pops briefly when it changes. */
export function GearPill(props: { main: string; suffix: string; size: number; trigger: number }) {
  const s = props.size;
  return (
    <div
      key={props.trigger}
      class={props.trigger > 0 ? "gear-pill pop" : "gear-pill"}
      style={{
        fontSize: `${s}px`,
        padding: `${s * 0.1}px ${s * 0.4}px ${s * 0.13}px`,
        borderRadius: `${s * 0.4}px`,
        boxShadow: `0 0 0 ${s * 0.135}px rgba(255,107,26,0.22)`,
      }}
    >
      <span class="num" style={{ fontWeight: 800 }}>
        {props.main}
      </span>
      <span style={{ fontSize: `${s * 0.43}px`, fontWeight: 700, opacity: 0.72, marginLeft: `${s * 0.07}px` }}>{props.suffix}</span>
    </div>
  );
}

/** ▲ / ▼ in the colour of the grade. */
export function GradeArrow(props: { grade: number; width: number; color: string }) {
  const w = props.width;
  const h = (w * 12) / 14;
  return (
    <svg width={w} height={h} viewBox="0 0 14 12" style={{ transform: props.grade < -0.05 ? "rotate(180deg)" : undefined, flex: "none" }} aria-hidden="true">
      <path d="M7 0l7 12H0z" fill={props.color} />
    </svg>
  );
}

/** Card container used in the main window. */
export function Card(props: { title?: string; children: ComponentChildren; class?: string }) {
  return (
    <section class={`card ${props.class ?? ""}`}>
      {props.title ? <MetricLabel text={props.title.toUpperCase()} size={12} /> : null}
      {props.children}
    </section>
  );
}

/** Selectable chip button. */
export function ChoiceChip(props: { title: string; selected: boolean; tint?: string; onClick: () => void }) {
  return (
    <button class={props.selected ? "chip selected" : "chip"} style={props.selected && props.tint ? { background: props.tint } : undefined} aria-pressed={props.selected} onClick={props.onClick}>
      {props.title}
    </button>
  );
}

export function Toggle(props: { label: string; checked: boolean; onChange: (value: boolean) => void }) {
  return (
    <label class="toggle">
      <input type="checkbox" checked={props.checked} onChange={(e) => props.onChange((e.currentTarget as HTMLInputElement).checked)} />
      <span class="switch" />
      <span>{props.label}</span>
    </label>
  );
}

export function Slider(props: { value: number; min: number; max: number; step: number; onInput: (value: number) => void }) {
  return (
    <input
      type="range"
      class="slider"
      min={props.min}
      max={props.max}
      step={props.step}
      value={props.value}
      onInput={(e) => props.onInput(Number((e.currentTarget as HTMLInputElement).value))}
    />
  );
}

/** − value + */
export function Stepper(props: { value: number; min: number; max: number; step?: number; onChange: (value: number) => void }) {
  const step = props.step ?? 1;
  const set = (v: number) => props.onChange(Math.min(props.max, Math.max(props.min, v)));
  return (
    <span class="stepper">
      <button aria-label="weniger" onClick={() => set(props.value - step)} disabled={props.value <= props.min}>
        −
      </button>
      <button aria-label="mehr" onClick={() => set(props.value + step)} disabled={props.value >= props.max}>
        +
      </button>
    </span>
  );
}

export function Spinner() {
  return <span class="spinner" role="status" aria-label="lädt" />;
}
