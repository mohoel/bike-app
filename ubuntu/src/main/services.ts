// Files on disk (settings, rides, workouts), the intervals.icu client and music control. No Electron in here.
import { spawn } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import dbus from "dbus-next";
import { PowerZones } from "../core/basics";
import { RideEntry, entryFromFIT } from "../core/ride";
import { FTPChange, MusicState, Settings, defaultSettings } from "../core/state";
import { Custom, CustomWorkout, IntervalsAthlete, IntervalsParser, Workout, isoDate, newId, parseAthlete, rideSettings, zonesOf, Block } from "../core/workout";

function writeAtomic(file: string, data: string | Uint8Array, mode?: number): void {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const tmp = `${file}.tmp-${process.pid}`;
  fs.writeFileSync(tmp, data, mode != null ? { mode } : undefined);
  fs.renameSync(tmp, file);
}

function readJSON<T>(file: string): T | null {
  try {
    return JSON.parse(fs.readFileSync(file, "utf8")) as T;
  } catch {
    return null;
  }
}

// MARK: - Settings

/** Persistent user settings as one JSON file. */
export class SettingsStore {
  private values: Settings;
  private saveTimer: ReturnType<typeof setTimeout> | null = null;
  onChange: () => void = () => undefined;

  constructor(private readonly file: string | null) {
    const stored = file ? readJSON<Partial<Settings>>(file) : null;
    this.values = { ...defaultSettings, ...(stored ?? {}) };
  }

  get(): Settings {
    return this.values;
  }

  set(patch: Partial<Settings>): void {
    this.values = { ...this.values, ...patch };
    this.onChange();
    if (!this.file) return;
    if (this.saveTimer) clearTimeout(this.saveTimer);
    this.saveTimer = setTimeout(() => this.flush(), 200);
  }

  flush(): void {
    if (this.saveTimer) clearTimeout(this.saveTimer);
    this.saveTimer = null;
    if (!this.file) return;
    try {
      writeAtomic(this.file, JSON.stringify(this.values, null, 2));
    } catch (error) {
      console.error("Einstellungen konnten nicht gespeichert werden:", error);
    }
  }
}

// MARK: - Custom workouts

/** Saves the workouts created in the app as one JSON file (same layout as the macOS app). */
export class CustomWorkoutStore {
  workouts: CustomWorkout[] = [];

  constructor(private readonly file: string) {
    const stored = readJSON<CustomWorkout[]>(file);
    if (Array.isArray(stored)) this.workouts = stored.map(normalizeWorkout);
  }

  workout(workoutId: string): CustomWorkout | null {
    return this.workouts.find((w) => Custom.workoutId(w) === workoutId) ?? null;
  }

  save(workout: CustomWorkout): CustomWorkout {
    const w = { ...normalizeWorkout(workout), modified: isoDate() };
    const index = this.workouts.findIndex((x) => x.id === w.id);
    if (index >= 0) this.workouts[index] = w;
    else this.workouts.unshift(w);
    this.persist();
    return w;
  }

  delete(id: string): void {
    this.workouts = this.workouts.filter((w) => w.id !== id);
    this.persist();
  }

  duplicate(id: string): CustomWorkout | null {
    const original = this.workouts.find((w) => w.id === id);
    if (!original) return null;
    return this.save({ ...original, id: newId(), name: `${original.name} (Kopie)`, blocks: original.blocks.map(Block.copy) });
  }

  private persist(): void {
    try {
      writeAtomic(this.file, JSON.stringify(this.workouts, null, 2));
    } catch (error) {
      console.error("Workouts konnten nicht gespeichert werden:", error);
    }
  }
}

function normalizeWorkout(w: CustomWorkout): CustomWorkout {
  const block = (b: any): any => ({
    id: b.id ?? newId(),
    kind: b.kind ?? "steady",
    duration: Number(b.duration ?? 300),
    startPercent: Number(b.startPercent ?? 75),
    endPercent: Number(b.endPercent ?? 75),
    label: b.label ?? "",
    reps: Number(b.reps ?? 3),
    children: Array.isArray(b.children) ? b.children.map(block) : [],
  });
  return { id: w.id ?? newId(), name: w.name ?? "Workout", notes: w.notes ?? "", blocks: (w.blocks ?? []).map(block), modified: w.modified ?? isoDate() };
}

// MARK: - intervals.icu

export class IntervalsError extends Error {}

/** REST client for intervals.icu (planned workouts, athlete data, activity upload). */
export class IntervalsClient {
  upcoming: Workout[] = [];
  library: Workout[] = [];
  load: { kind: "idle" | "loading" | "loaded" | "failed"; message?: string } = { kind: "idle" };
  athlete: IntervalsAthlete | null = null;
  lastRefresh: number | null = null;
  onChange: () => void = () => undefined;

  constructor(
    private readonly settings: () => Settings,
    public apiKey: string,
    private readonly storeKey: (key: string) => void = () => undefined,
    private readonly http: typeof fetch = (...args) => fetch(...args),
  ) {}

  get isConfigured(): boolean {
    return this.apiKey !== "";
  }

  setAPIKey(key: string): void {
    this.apiKey = key.trim();
    this.storeKey(this.apiKey);
    if (!this.isConfigured) {
      this.load = { kind: "idle" };
      this.athlete = null;
      this.upcoming = [];
      this.library = [];
    }
    this.onChange();
  }

  /** FTP to use for targets: intervals.icu value if enabled and available, else the manual setting. */
  get effectiveFTP(): number {
    const s = this.settings();
    if (s.useIntervalsFTP && this.athlete?.ftp != null && this.athlete.ftp > 0) return this.athlete.ftp;
    return s.ftp;
  }

  get zones(): PowerZones {
    return zonesOf(this.athlete?.zones);
  }

  private get athleteId(): string {
    const id = this.settings().intervalsAthleteId.trim();
    return id === "" ? "0" : id;
  }

  async refreshAll(): Promise<void> {
    if (!this.isConfigured) {
      this.load = { kind: "idle" };
      this.onChange();
      return;
    }
    this.load = { kind: "loading" };
    this.onChange();
    try {
      await this.fetchAthlete();
      await this.fetchUpcoming();
      await this.fetchLibrary().catch(() => undefined);
      this.load = { kind: "loaded" };
      this.lastRefresh = Date.now();
    } catch (error) {
      this.load = { kind: "failed", message: errorText(error) };
    }
    this.onChange();
  }

  /** Reloads planned workouts if the last refresh is older than `maxAge` seconds. */
  async refreshIfStale(maxAge = 300): Promise<void> {
    if (!this.isConfigured || this.load.kind === "loading") return;
    if (this.lastRefresh != null && (Date.now() - this.lastRefresh) / 1000 < maxAge) return;
    await this.refreshAll();
  }

  async fetchAthlete(): Promise<void> {
    this.athlete = parseAthlete(await this.getJSON(""));
  }

  async fetchUpcoming(): Promise<void> {
    const today = new Date();
    const end = new Date(today.getFullYear(), today.getMonth(), today.getDate() + 7);
    const json = await this.getJSON("events", { oldest: localDay(today), newest: localDay(end), category: "WORKOUT", resolve: "true" });
    this.upcoming = IntervalsParser.parseEvents(json, this.effectiveFTP).sort((a, b) => (a.date ?? "9999").localeCompare(b.date ?? "9999"));
  }

  async fetchLibrary(): Promise<void> {
    this.library = IntervalsParser.parseLibrary(await this.getJSON("workouts"), this.effectiveFTP);
  }

  /** Uploads a FIT file as a new activity. Returns the activity id. */
  async upload(fit: Uint8Array, filename: string, name: string, description: string | null, pairedEventId: number | null): Promise<string> {
    const query: Record<string, string> = { name };
    if (description) query.description = description;
    if (pairedEventId != null) query.paired_event_id = String(pairedEventId);
    const form = new FormData();
    form.append("file", new Blob([fit as BlobPart], { type: "application/octet-stream" }), filename);
    const response = await this.request("POST", "activities", query, form);
    try {
      const json = (await response.json()) as { id?: unknown };
      return json?.id != null ? String(json.id) : "";
    } catch {
      return "";
    }
  }

  /**
   * Writes a new FTP into the cycling sport settings.
   * Updates the indoor FTP if one is set there, otherwise the FTP. Returns the change for undo.
   */
  async updateFTP(watts: number): Promise<FTPChange> {
    const ride = rideSettings(await this.getJSON(""));
    if (!ride) throw new IntervalsError("In intervals.icu gibt es keine Einstellungen für Radfahren.");
    const field = ride.indoorFTP != null ? "indoor_ftp" : "ftp";
    const previous = field === "indoor_ftp" ? ride.indoorFTP : ride.ftp;
    await this.request("PUT", `sport-settings/${ride.id}`, {}, JSON.stringify({ [field]: watts }));
    await this.fetchAthlete().catch(() => undefined);
    this.onChange();
    return { settingsId: ride.id, field, previous, new: watts };
  }

  /** Puts the previous value back. */
  async restoreFTP(change: FTPChange): Promise<void> {
    await this.request("PUT", `sport-settings/${change.settingsId}`, {}, JSON.stringify({ [change.field]: change.previous }));
    await this.fetchAthlete().catch(() => undefined);
    this.onChange();
  }

  /** API URL without trailing slash, e.g. …/athlete/0 or …/athlete/0/events. */
  static url(athleteId: string, apiPath: string): string {
    const trimmed = apiPath.replace(/^\/+|\/+$/g, "");
    return `https://intervals.icu/api/v1/athlete/${encodeURIComponent(athleteId)}${trimmed === "" ? "" : `/${trimmed}`}`;
  }

  private async getJSON(apiPath: string, query: Record<string, string> = {}): Promise<any> {
    const response = await this.request("GET", apiPath, query);
    return response.json();
  }

  private async request(method: string, apiPath: string, query: Record<string, string>, body?: string | FormData): Promise<Response> {
    if (!this.isConfigured) throw new IntervalsError("Kein API-Key für intervals.icu hinterlegt.");
    const url = new URL(IntervalsClient.url(this.athleteId, apiPath));
    for (const [key, value] of Object.entries(query)) url.searchParams.set(key, value);
    const headers: Record<string, string> = {
      Authorization: "Basic " + Buffer.from(`API_KEY:${this.apiKey}`).toString("base64"),
      Accept: "application/json",
    };
    if (typeof body === "string") headers["Content-Type"] = "application/json";
    const response = await this.http(url, { method, headers, body });
    if (!response.ok) {
      const text = await response.text().catch(() => "");
      if (response.status === 401 || response.status === 403) throw new IntervalsError(`intervals.icu lehnt den API-Key ab (${response.status}).`);
      throw new IntervalsError(`intervals.icu antwortet mit Fehler ${response.status}. ${text.slice(0, 160)}`);
    }
    return response;
  }
}

function localDay(date: Date): string {
  const p = (n: number) => String(n).padStart(2, "0");
  return `${date.getFullYear()}-${p(date.getMonth() + 1)}-${p(date.getDate())}`;
}

export function errorText(error: unknown): string {
  if (error instanceof IntervalsError) return error.message;
  const message = (error as Error)?.message ?? String(error);
  if (/fetch failed|ENOTFOUND|ECONN|network/i.test(message)) return "Keine Verbindung zu intervals.icu.";
  return message;
}

// MARK: - Ride store

/**
 * Keeps every finished ride on disk (FIT file plus metadata) and uploads rides that are not on intervals.icu yet.
 *
 * Rides are saved before any upload attempt, so a ride without API key or without network
 * is uploaded later: when a key is saved, when the app starts and when it becomes active.
 * The FIT file is what intervals.icu needs; the metadata holds the figures and curves for the history.
 */
export class RideStore {
  private uploading = false;

  constructor(readonly directory: string) {}

  private metaPath(id: string): string {
    return path.join(this.directory, `${id}.json`);
  }

  private fitPath(id: string): string {
    return path.join(this.directory, id);
  }

  save(fit: Uint8Array, entry: RideEntry): void {
    try {
      writeAtomic(this.fitPath(entry.id), fit);
      this.write(entry);
    } catch (error) {
      console.error("Fahrt konnte nicht gesichert werden:", error);
    }
  }

  private write(entry: RideEntry): void {
    writeAtomic(this.metaPath(entry.id), JSON.stringify(entry));
  }

  private files(): string[] {
    try {
      return fs.readdirSync(this.directory);
    } catch {
      return [];
    }
  }

  entries(): RideEntry[] {
    return this.files()
      .filter((f) => f.endsWith(".json"))
      .map((f) => readJSON<RideEntry>(path.join(this.directory, f)))
      .filter((e): e is RideEntry => e != null && typeof e.id === "string" && typeof e.date === "string")
      .sort((a, b) => Date.parse(b.date) - Date.parse(a.date));
  }

  entry(id: string): RideEntry | null {
    return readJSON<RideEntry>(this.metaPath(id));
  }

  fit(id: string): Uint8Array | null {
    try {
      return new Uint8Array(fs.readFileSync(this.fitPath(id)));
    } catch {
      return null;
    }
  }

  update(id: string, change: (entry: RideEntry) => void): void {
    const entry = this.entry(id);
    if (!entry) return;
    change(entry);
    try {
      this.write(entry);
    } catch {
      /* keep the old metadata */
    }
  }

  /** Deletes a ride from this computer (not from intervals.icu). */
  delete(id: string): void {
    fs.rmSync(this.fitPath(id), { force: true });
    fs.rmSync(this.metaPath(id), { force: true });
  }

  /** Uploads one stored ride. Returns the activity id. */
  async upload(id: string, client: IntervalsClient): Promise<string> {
    const entry = this.entry(id);
    const fit = this.fit(id);
    if (!entry || !fit) throw new IntervalsError("Die gesicherte Fahrt wurde nicht gefunden.");
    try {
      const activity = await client.upload(fit, entry.id, entry.name, entry.description ?? null, entry.pairedEventId ?? null);
      this.update(id, (e) => {
        e.uploadedActivityId = activity === "" ? "ok" : activity;
        e.lastError = null;
      });
      return activity;
    } catch (error) {
      this.update(id, (e) => {
        e.lastError = errorText(error);
      });
      throw error;
    }
  }

  /** Uploads every ride that is not on intervals.icu yet. Returns the number of uploads. */
  async uploadPending(client: IntervalsClient): Promise<number> {
    if (!client.isConfigured || this.uploading) return 0;
    this.uploading = true;
    let done = 0;
    try {
      for (const entry of this.entries().filter((e) => !e.uploadedActivityId)) {
        try {
          await this.upload(entry.id, client);
          done += 1;
        } catch {
          /* stays pending */
        }
      }
    } finally {
      this.uploading = false;
    }
    return done;
  }

  /** Adds a FIT file from disk (for example one saved by hand) to the store. */
  importFIT(file: string, ftp: number, zones: PowerZones): RideEntry {
    const data = new Uint8Array(fs.readFileSync(file));
    const base = path.basename(file);
    let id = base.toLowerCase().endsWith(".fit") ? base : `${base}.fit`;
    const existing = this.fit(id);
    if (this.entry(id) && !(existing && Buffer.from(existing).equals(Buffer.from(data)))) {
      id = `${path.basename(file, path.extname(file))}-${newId().slice(0, 6)}.fit`;
    }
    const entry = entryFromFIT(data, id, path.basename(file, path.extname(file)), ftp, zones);
    this.save(data, entry);
    return entry;
  }

  /** FIT files placed in the folder by hand get a history entry. */
  adoptLooseFiles(ftp: number, zones: PowerZones): void {
    const files = this.files();
    for (const file of files) {
      if (!file.toLowerCase().endsWith(".fit") || files.includes(`${file}.json`)) continue;
      const data = this.fit(file);
      if (!data) continue;
      try {
        this.write(entryFromFIT(data, file, file, ftp, zones));
      } catch {
        /* not a readable FIT file */
      }
    }
  }

  /** Fills in figures and curves for entries created before the history existed. */
  completeDetails(ftp: number, zones: PowerZones): void {
    for (const old of this.entries()) {
      if (old.series != null) continue;
      const data = this.fit(old.id);
      if (!data) continue;
      try {
        const entry = entryFromFIT(data, old.id, old.name, ftp, zones);
        this.write({
          ...entry,
          name: old.name,
          subtitle: old.subtitle,
          description: old.description,
          pairedEventId: old.pairedEventId,
          uploadedActivityId: old.uploadedActivityId,
          lastError: old.lastError,
        });
      } catch {
        /* leave the entry as it is */
      }
    }
  }
}

// MARK: - Music (MPRIS)

const { Message, Variant } = dbus;
const MPRIS_PATH = "/org/mpris/MediaPlayer2";
const MPRIS_PLAYER = "org.mpris.MediaPlayer2.Player";

function plain(value: any): any {
  if (value instanceof Variant) return plain(value.value);
  if (Array.isArray(value)) return value.map(plain);
  if (value && typeof value === "object" && !Buffer.isBuffer(value)) {
    const out: Record<string, any> = {};
    for (const [k, v] of Object.entries(value)) out[k] = plain(v);
    return out;
  }
  return value;
}

/** Parses the MPRIS player properties into the music state. */
export function parseMprisProperties(properties: Record<string, any>): { playing: boolean; track: MusicState["track"] } {
  const status = String(properties.PlaybackStatus ?? "").toLowerCase();
  const metadata = properties.Metadata ?? {};
  const title = metadata["xesam:title"];
  if (status === "stopped" || !title) return { playing: status === "playing", track: null };
  const artists = metadata["xesam:artist"];
  const art = metadata["mpris:artUrl"];
  return {
    playing: status === "playing",
    track: {
      id: String(metadata["mpris:trackid"] ?? title),
      name: String(title),
      artist: Array.isArray(artists) ? artists.join(", ") : String(artists ?? ""),
      artworkURL: typeof art === "string" && /^https:\/\//.test(art) ? art : null,
    },
  };
}

/**
 * Shows and controls what Spotify is playing, over MPRIS on the session bus.
 *
 * Commands go to Spotify directly (not to "the active player"), so a series
 * playing in the browser is never paused by accident. Spotify is never launched unless
 * the user asks for it.
 */
export class MusicController {
  static readonly busName = "org.mpris.MediaPlayer2.spotify";

  state: MusicState = { installed: false, running: false, playing: false, track: null };
  onChange: () => void = () => undefined;
  private bus: dbus.MessageBus | null = null;
  private pollTimer: ReturnType<typeof setInterval> | null = null;

  /** Starts watching Spotify (called when a ride starts, so nothing happens at app launch). */
  start(): void {
    if (process.platform !== "linux" || this.pollTimer) return;
    this.state.installed = MusicController.findSpotify() != null;
    try {
      if (!this.bus) {
        this.bus = dbus.sessionBus();
        this.bus.on("error", () => undefined);
      }
    } catch {
      this.bus = null;
      return;
    }
    void this.refresh();
    this.pollTimer = setInterval(() => void this.refresh(), 2000);
  }

  stop(): void {
    if (this.pollTimer) clearInterval(this.pollTimer);
    this.pollTimer = null;
  }

  private static findSpotify(): string | null {
    const candidates = ["/usr/bin/spotify", "/snap/bin/spotify", "/usr/local/bin/spotify", "/var/lib/flatpak/exports/bin/com.spotify.Client"];
    const home = process.env.HOME;
    if (home) candidates.push(path.join(home, ".local/share/flatpak/exports/bin/com.spotify.Client"));
    return candidates.find((c) => fs.existsSync(c)) ?? null;
  }

  private async call(destination: string, objectPath: string, iface: string, member: string, signature?: string, body?: any[]): Promise<any[]> {
    if (!this.bus) throw new Error("kein Session-Bus");
    const reply = await this.bus.call(new Message({ destination, path: objectPath, interface: iface, member, signature, body }));
    return reply?.body ?? [];
  }

  async refresh(): Promise<void> {
    const before = JSON.stringify(this.state);
    try {
      const [running] = await this.call("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "NameHasOwner", "s", [MusicController.busName]);
      if (!running) {
        this.state = { ...this.state, running: false, playing: false, track: null };
      } else {
        const [properties] = await this.call(MusicController.busName, MPRIS_PATH, "org.freedesktop.DBus.Properties", "GetAll", "s", [MPRIS_PLAYER]);
        this.state = { installed: true, running: true, ...parseMprisProperties(plain(properties)) };
      }
    } catch {
      this.state = { ...this.state, running: false, playing: false, track: null };
    }
    if (JSON.stringify(this.state) !== before) this.onChange();
  }

  private command(member: string): void {
    if (!this.state.running) return;
    this.call(MusicController.busName, MPRIS_PATH, MPRIS_PLAYER, member)
      .catch(() => undefined)
      .then(() => setTimeout(() => void this.refresh(), 400));
  }

  playPause(): void {
    if (!this.state.running) return;
    this.state = { ...this.state, playing: !this.state.playing };
    this.onChange();
    this.command("PlayPause");
  }

  next(): void {
    this.command("Next");
  }

  previous(): void {
    this.command("Previous");
  }

  /** Opens Spotify in the background and starts playback. */
  launchAndPlay(): void {
    const binary = MusicController.findSpotify();
    if (!binary) return;
    try {
      spawn(binary, [], { detached: true, stdio: "ignore" }).unref();
    } catch {
      return;
    }
    setTimeout(() => {
      this.call(MusicController.busName, MPRIS_PATH, MPRIS_PLAYER, "Play").catch(() => undefined);
      void this.refresh();
    }, 4000);
  }
}
