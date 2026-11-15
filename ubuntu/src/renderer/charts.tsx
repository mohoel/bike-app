// Canvas charts: elevation profile, workout blocks, power, heart rate, zones.
import { ComponentChildren } from "preact";
import { useEffect, useRef } from "preact/hooks";
import { PowerZones, Theme } from "../core/basics";
import { ProfileColumn } from "../core/elevation";
import { PowerPoint } from "../core/engine";
import { StoredSeries } from "../core/ride";
import { Step, WorkoutStep } from "../core/workout";

type Draw = (ctx: CanvasRenderingContext2D, width: number, height: number) => void;

/** A canvas that draws in layout pixels and stays sharp at any scale and pixel ratio. */
export function Canvas(props: { draw: Draw; height?: number; class?: string; style?: Record<string, string | number> }) {
  const ref = useRef<HTMLCanvasElement>(null);
  const draw = useRef(props.draw);
  draw.current = props.draw;

  const paint = () => {
    const canvas = ref.current;
    if (!canvas) return;
    const rect = canvas.getBoundingClientRect();
    const layoutWidth = canvas.offsetWidth;
    const layoutHeight = canvas.offsetHeight;
    if (layoutWidth <= 0 || layoutHeight <= 0) return;
    const ratio = window.devicePixelRatio || 1;
    const w = Math.max(1, Math.round(rect.width * ratio));
    const h = Math.max(1, Math.round(rect.height * ratio));
    if (canvas.width !== w || canvas.height !== h) {
      canvas.width = w;
      canvas.height = h;
    }
    const ctx = canvas.getContext("2d");
    if (!ctx) return;
    ctx.setTransform(1, 0, 0, 1, 0, 0);
    ctx.clearRect(0, 0, w, h);
    ctx.setTransform(w / layoutWidth, 0, 0, h / layoutHeight, 0, 0);
    draw.current(ctx, layoutWidth, layoutHeight);
  };

  useEffect(paint);
  useEffect(() => {
    const canvas = ref.current;
    if (!canvas) return;
    const observer = new ResizeObserver(paint);
    observer.observe(canvas);
    window.addEventListener("resize", paint);
    return () => {
      observer.disconnect();
      window.removeEventListener("resize", paint);
    };
  }, []);

  const style = { display: "block", width: "100%", height: props.height != null ? `${props.height}px` : "100%", ...(props.style ?? {}) };
  return <canvas ref={ref} class={props.class} style={style} aria-hidden="true" />;
}

function roundedRect(ctx: CanvasRenderingContext2D, x: number, y: number, w: number, h: number, r: number) {
  ctx.beginPath();
  ctx.roundRect(x, y, w, h, Math.max(0, Math.min(r, w / 2, h / 2)));
}

/** Elevation profile as coloured columns, coloured by grade. */
export function ProfileBars(props: {
  columns: ProfileColumn[];
  /** Position 0…1 of the rider; columns before it are dimmed. */
  marker: number | null;
  spacing?: number;
  minHeight?: number;
  dimAll?: boolean;
  highlightCurrent?: boolean;
  height?: number;
}) {
  const { columns, marker, spacing = 2, minHeight = 5, dimAll = false, highlightCurrent = true } = props;
  return (
    <Canvas
      height={props.height}
      draw={(ctx, width, height) => {
        if (columns.length === 0) return;
        const n = columns.length;
        const w = Math.max(0.5, (width - spacing * (n - 1)) / n);
        const current = marker != null ? Math.min(n - 1, Math.floor(marker * n)) : null;
        columns.forEach((c, i) => {
          const h = minHeight + c.norm * (height - minHeight);
          const x = i * (w + spacing);
          const isCurrent = highlightCurrent && i === current;
          roundedRect(ctx, x, height - h, w, h, Math.min(2, w / 2));
          if (isCurrent && !dimAll) {
            ctx.save();
            ctx.shadowColor = "rgba(255,255,255,0.85)";
            ctx.shadowBlur = 5 * (ctx.getTransform().a || 1);
            ctx.fillStyle = "#fff";
            ctx.fill();
            ctx.restore();
            return;
          }
          let alpha = 1;
          if (dimAll) alpha = isCurrent ? 0.6 : 0.22;
          else if (current != null && i < current) alpha = 0.32;
          ctx.globalAlpha = alpha;
          ctx.fillStyle = isCurrent ? "#fff" : Theme.gradeColor(c.grade);
          ctx.fill();
          ctx.globalAlpha = 1;
        });
      }}
    />
  );
}

/** Workout as blocks in zone colours, done part dimmed. */
export function WorkoutChart(props: {
  steps: WorkoutStep[];
  elapsed: number;
  zones: PowerZones;
  gap?: number;
  minHeight?: number;
  /** Highest fraction of FTP that fills the full height. */
  top?: number;
  /** Draws a white line in the current block (bar style). */
  inBlockMarker?: boolean;
  trace?: PowerPoint[];
  ftp?: number;
  ftpLine?: boolean;
  height?: number;
  opacity?: number;
}) {
  const { steps, elapsed, zones, gap = 2, minHeight = 6, top = 1.2, inBlockMarker = true, trace = [], ftp = 250, ftpLine = false } = props;
  return (
    <Canvas
      height={props.height}
      style={props.opacity != null ? { opacity: props.opacity } : undefined}
      draw={(ctx, width, height) => {
        const total = steps.reduce((s, x) => s + x.duration, 0);
        if (!(total > 0)) return;
        const usable = width - gap * Math.max(0, steps.length - 1);
        const level = (fraction: number) => minHeight + Math.min(1, fraction / top) * (height - minHeight);
        let x = 0;
        let t = 0;
        for (const step of steps) {
          const w = usable * (step.duration / total);
          const start = step.startFraction ?? 0.5;
          const end = step.endFraction ?? start;
          const h0 = level(start);
          const h1 = level(end);
          const path = () => {
            ctx.beginPath();
            ctx.moveTo(x, height);
            ctx.lineTo(x, height - h0);
            ctx.lineTo(x + w, height - h1);
            ctx.lineTo(x + w, height);
            ctx.closePath();
          };
          const color = Step.hasTarget(step) ? Theme.zoneColor(zones.indexForFraction((start + end) / 2)) : "rgba(255,255,255,0.35)";
          const fill = (alpha: number, clipX?: number, clipW?: number) => {
            ctx.save();
            if (clipX != null && clipW != null) {
              ctx.beginPath();
              ctx.rect(clipX, 0, clipW, height);
              ctx.clip();
            }
            path();
            ctx.globalAlpha = alpha;
            ctx.fillStyle = color;
            ctx.fill();
            ctx.restore();
          };
          const stepEnd = t + step.duration;
          if (stepEnd <= elapsed) {
            fill(0.32);
          } else if (t >= elapsed) {
            fill(1);
          } else {
            const splitX = x + w * ((elapsed - t) / step.duration);
            fill(0.32, x, splitX - x);
            fill(1, splitX, x + w - splitX);
            if (inBlockMarker) {
              ctx.save();
              path();
              ctx.clip();
              ctx.fillStyle = "#fff";
              ctx.fillRect(splitX, 0, Math.max(1.5, w * 0.015), height);
              ctx.restore();
            }
          }
          x += w + gap;
          t = stepEnd;
        }
        if (ftpLine) {
          const y = height - level(1);
          ctx.save();
          ctx.setLineDash([4, 4]);
          ctx.strokeStyle = "rgba(255,255,255,0.35)";
          ctx.lineWidth = 1;
          ctx.beginPath();
          ctx.moveTo(0, y);
          ctx.lineTo(width, y);
          ctx.stroke();
          ctx.restore();
        }
        if (trace.length > 1 && ftp > 0) {
          ctx.beginPath();
          trace.forEach((p, i) => {
            const px = width * (p.time / total);
            const py = height - level(p.watts / ftp);
            if (i === 0) ctx.moveTo(px, py);
            else ctx.lineTo(px, py);
          });
          ctx.strokeStyle = "#fff";
          ctx.lineWidth = 2;
          ctx.lineJoin = "round";
          ctx.stroke();
        }
      }}
    />
  );
}

/** Power over time as columns in zone colours. */
export function PowerBars(props: { power: number[]; ftp: number; zones: PowerZones; spacing?: number; height?: number }) {
  const { power, ftp, zones, spacing = 1 } = props;
  return (
    <Canvas
      height={props.height}
      draw={(ctx, width, height) => {
        if (power.length === 0) return;
        const top = Math.max(Math.max(...power), ftp * 1.2, 1);
        const n = power.length;
        const gap = n * (spacing + 0.5) < width ? spacing : 0;
        const w = Math.max(0.5, (width - gap * (n - 1)) / n);
        power.forEach((p, i) => {
          const h = Math.max(1.5, (p / top) * height);
          roundedRect(ctx, i * (w + gap), height - h, w, h, Math.min(1.5, w / 2));
          ctx.fillStyle = p > 0 ? Theme.zoneColor(zones.index(p, ftp)) : "rgba(255,255,255,0.15)";
          ctx.fill();
        });
      }}
    />
  );
}

/** Heart rate as a line with a soft fill. */
export function HeartRateLine(props: { values: number[]; height?: number }) {
  const { values } = props;
  return (
    <Canvas
      height={props.height}
      draw={(ctx, width, height) => {
        const present = values.filter((v) => v > 0);
        if (present.length === 0 || values.length < 2) return;
        const minY = Math.min(...present) - 5;
        const maxY = Math.max(...present) + 5;
        const point = (i: number) => ({ x: (width * i) / (values.length - 1), y: height * (1 - (values[i] - minY) / (maxY - minY)) });
        const points = values.map((v, i) => (v > 0 ? point(i) : null)).filter((p): p is { x: number; y: number } => p != null);
        ctx.beginPath();
        ctx.moveTo(points[0].x, height);
        for (const p of points) ctx.lineTo(p.x, p.y);
        ctx.lineTo(points[points.length - 1].x, height);
        ctx.closePath();
        ctx.fillStyle = "rgba(255,92,122,0.14)";
        ctx.fill();
        ctx.beginPath();
        points.forEach((p, i) => (i === 0 ? ctx.moveTo(p.x, p.y) : ctx.lineTo(p.x, p.y)));
        ctx.strokeStyle = Theme.heart;
        ctx.lineWidth = 2;
        ctx.lineJoin = "round";
        ctx.stroke();
      }}
    />
  );
}

/** Share of time in each power zone as one coloured bar. */
export function ZoneDistributionBar(props: { seconds: number[]; height: number }) {
  const total = props.seconds.reduce((s, x) => s + x, 0);
  return (
    <div class="zone-bar" style={{ height: `${props.height}px` }} aria-hidden="true">
      {total > 0 ? (
        props.seconds.map((value, i) => (value > 0 ? <span key={i} style={{ flexGrow: value, background: Theme.zoneColor(i) }} /> : null))
      ) : (
        <span style={{ flexGrow: 1, background: "rgba(255,255,255,0.08)" }} />
      )}
    </div>
  );
}

/** Six small bars, the current power zone lit up. */
export function ZoneSegments(props: { active: number | null; width: number; height: number; spacing: number }) {
  return (
    <div style={{ display: "flex", gap: `${props.spacing}px` }} aria-hidden="true">
      {[0, 1, 2, 3, 4, 5].map((i) => (
        <span
          key={i}
          style={{ width: `${props.width}px`, height: `${props.height}px`, borderRadius: `${props.height}px`, background: Theme.zoneColor(i), opacity: i === props.active ? 1 : 0.28 }}
        />
      ))}
    </div>
  );
}

/** Elevation columns from the stored altitude and distance, coloured by grade. */
export function altitudeColumns(series: StoredSeries): ProfileColumn[] {
  const alt = series.altitude;
  if (alt.length < 2) return [];
  const lo = Math.min(...alt);
  const hi = Math.max(...alt);
  if (hi - lo < 1) return [];
  const span = Math.max(hi - lo, 30);
  return alt.map((a, i) => {
    let grade = 0;
    if (i > 0 && i < series.distance.length) {
      const d = series.distance[i] - series.distance[i - 1];
      if (d > 1) grade = ((a - alt[i - 1]) / d) * 100;
    }
    return { norm: (a - lo) / span, grade };
  });
}

/** Scales a fixed-size design to the available width (and optionally height). */
export function Scaled(props: { width: number; height: number; scale: number; children: ComponentChildren }) {
  return (
    <div style={{ width: `${props.width * props.scale}px`, height: `${props.height * props.scale}px`, flex: "none" }}>
      <div style={{ width: `${props.width}px`, height: `${props.height}px`, transform: `scale(${props.scale})`, transformOrigin: "0 0" }}>{props.children}</div>
    </div>
  );
}
