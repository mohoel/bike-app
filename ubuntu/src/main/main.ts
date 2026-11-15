// Electron entry: windows (main, floating bar, full screen), shortcuts, tray and the bridge to the windows.
import { BrowserWindow, Menu, Tray, app, clipboard, dialog, globalShortcut, ipcMain, nativeImage, safeStorage, screen, shell } from "electron";
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { rideFromFIT } from "../core/ride";
import { Settings } from "../core/state";
import { CustomWorkout } from "../core/workout";
import { BlueZTransport } from "./ble/bluez";
import { AppModel, StartRequest } from "./model";

const isLinux = process.platform === "linux";
const argValue = (name: string) => process.argv.find((a) => a.startsWith(`--${name}=`))?.slice(name.length + 3) ?? null;
const hasFlag = (name: string) => process.argv.includes(`--${name}`);
const smokeDirectory = argValue("smoke-test");
/** Smoke test without visible windows (for development machines). */
const headless = smokeDirectory != null && hasFlag("headless");

// The floating bar needs "always on top", free positioning and global shortcuts. Wayland offers none of
// them to applications, so the app runs through XWayland (the .desktop file passes the same switch).
if (isLinux && process.env.XDG_SESSION_TYPE === "wayland" && !process.argv.some((a) => a.startsWith("--ozone-platform") || a.startsWith("--action=")) && !process.env.BIKEAPP_NATIVE_WAYLAND) {
  app.relaunch({ args: [...process.argv.slice(1), "--ozone-platform=x11"] });
  app.exit(0);
}

const OVERLAY = { baseWidth: 980, barHeight: 128, controlsHeight: 172, minWidth: 560, maxWidth: 2400 };
const overlayAspect = (controls: boolean) => OVERLAY.baseWidth / (controls ? OVERLAY.controlsHeight : OVERLAY.barHeight);
const SHORTCUT_PREFIX = "Strg+Alt";

function dataDirectory(): string {
  if (process.env.BIKEAPP_DATA_DIR) return process.env.BIKEAPP_DATA_DIR;
  if (smokeDirectory) return fs.mkdtempSync(path.join(os.tmpdir(), "bikeapp-smoke-"));
  if (isLinux) return path.join(process.env.XDG_DATA_HOME || path.join(os.homedir(), ".local/share"), "BikeApp");
  return path.join(app.getPath("userData"), "data");
}

// MARK: API key storage (system keyring through Electron's safeStorage)

function secretsFile(dir: string): string {
  return path.join(dir, "secrets.json");
}

function readAPIKey(dir: string): string {
  try {
    const stored = JSON.parse(fs.readFileSync(secretsFile(dir), "utf8")) as { apiKey?: string; apiKeyPlain?: string };
    if (stored.apiKey && safeStorage.isEncryptionAvailable()) return safeStorage.decryptString(Buffer.from(stored.apiKey, "base64"));
    return stored.apiKeyPlain ?? "";
  } catch {
    return "";
  }
}

function storeAPIKey(dir: string, key: string): void {
  try {
    if (key === "") {
      fs.rmSync(secretsFile(dir), { force: true });
      return;
    }
    const content = safeStorage.isEncryptionAvailable()
      ? { apiKey: safeStorage.encryptString(key).toString("base64") }
      : { apiKeyPlain: key };
    fs.mkdirSync(dir, { recursive: true });
    fs.writeFileSync(secretsFile(dir), JSON.stringify(content), { mode: 0o600 });
  } catch (error) {
    console.error("API-Key konnte nicht gespeichert werden:", error);
  }
}

// MARK: App

let model: AppModel;
let mainWindow: BrowserWindow | null = null;
let overlayWindow: BrowserWindow | null = null;
let fullscreenWindow: BrowserWindow | null = null;
let closingFullscreen = false;
let tray: Tray | null = null;
let quitting = false;
let dragStart: { x: number; y: number; width: number; height: number } | null = null;

const rendererFile = path.join(__dirname, "renderer", "index.html");
const iconFile = path.join(__dirname, "icon.png");

function windows(): BrowserWindow[] {
  return [mainWindow, overlayWindow, fullscreenWindow].filter((w): w is BrowserWindow => w != null && !w.isDestroyed());
}

function send(channel: string, payload: unknown): void {
  for (const w of windows()) w.webContents.send(channel, payload);
}

function webPreferences(): Electron.WebPreferences {
  return { preload: path.join(__dirname, "preload.js"), contextIsolation: true, nodeIntegration: false, sandbox: true, backgroundThrottling: !headless };
}

function createMainWindow(): BrowserWindow {
  const win = new BrowserWindow({
    width: 880,
    height: 860,
    minWidth: 760,
    minHeight: 640,
    title: "Bike App",
    backgroundColor: "#0B0D12",
    icon: iconFile,
    autoHideMenuBar: true,
    show: !headless,
    webPreferences: webPreferences(),
  });
  win.loadFile(rendererFile, { query: { view: "main" } });
  win.on("focus", () => model.appDidBecomeActive());
  win.on("close", (event) => {
    // Closing the window during a ride keeps the ride running (tray and bar stay).
    if (!quitting && model.isRiding) {
      event.preventDefault();
      win.hide();
    }
  });
  win.on("closed", () => {
    mainWindow = null;
  });
  win.webContents.setWindowOpenHandler(({ url }) => {
    openExternal(url);
    return { action: "deny" };
  });
  mainWindow = win;
  return win;
}

function showMainWindow(): void {
  if (headless) return;
  const win = mainWindow ?? createMainWindow();
  if (win.isMinimized()) win.restore();
  win.show();
  win.focus();
}

function openExternal(url: string): void {
  if (/^https:\/\/intervals\.icu\//.test(url)) void shell.openExternal(url);
}

// MARK: Floating bar

function overlayBounds(): Electron.Rectangle {
  const s = model.s;
  const aspect = overlayAspect(s.showControlRow);
  const area = screen.getPrimaryDisplay().workArea;
  const stored = s.overlayBounds;
  const width = Math.round(Math.min(OVERLAY.maxWidth, Math.max(OVERLAY.minWidth, stored?.width ?? Math.min(OVERLAY.baseWidth, area.width - 40))));
  const height = Math.round(width / aspect);
  let x = stored?.x ?? Math.round(area.x + (area.width - width) / 2);
  let y = stored?.y ?? area.y + area.height - height - 40;
  // Keep the bar reachable when the screen layout changed.
  const visible = screen.getAllDisplays().some((d) => x + 80 > d.bounds.x && x < d.bounds.x + d.bounds.width - 80 && y + 40 > d.bounds.y && y < d.bounds.y + d.bounds.height - 40);
  if (!visible) {
    x = Math.round(area.x + (area.width - width) / 2);
    y = area.y + area.height - height - 40;
  }
  return { x, y, width, height };
}

function createOverlay(): BrowserWindow {
  const win = new BrowserWindow({
    ...overlayBounds(),
    show: false,
    frame: false,
    transparent: true,
    resizable: false,
    movable: true,
    skipTaskbar: true,
    focusable: false,
    alwaysOnTop: true,
    hasShadow: false,
    fullscreenable: false,
    title: "Bike App – Leiste",
    webPreferences: webPreferences(),
  });
  win.setAlwaysOnTop(true, "screen-saver");
  win.setVisibleOnAllWorkspaces(true, { visibleOnFullScreen: true });
  win.loadFile(rendererFile, { query: { view: "overlay" } });
  win.on("closed", () => {
    overlayWindow = null;
  });
  overlayWindow = win;
  return win;
}

function showOverlay(): void {
  const win = overlayWindow ?? createOverlay();
  win.setBounds(overlayBounds());
  win.setIgnoreMouseEvents(model.clickThrough);
  if (headless) return;
  win.showInactive();
  win.setAlwaysOnTop(true, "screen-saver");
}

function hideOverlay(): void {
  overlayWindow?.hide();
}

function saveOverlayBounds(): void {
  if (!overlayWindow || overlayWindow.isDestroyed()) return;
  const b = overlayWindow.getBounds();
  model.settings.set({ overlayBounds: { x: b.x, y: b.y, width: b.width } });
}

/** Fits the bar height to its width when the control row is switched on or off (the bottom edge stays). */
function applyOverlayLayout(): void {
  const win = overlayWindow;
  if (!win || win.isDestroyed()) return;
  const b = win.getBounds();
  const height = Math.round(b.width / overlayAspect(model.s.showControlRow));
  if (Math.abs(height - b.height) < 1) return;
  win.setBounds({ x: b.x, y: Math.max(0, b.y + b.height - height), width: b.width, height });
  saveOverlayBounds();
}

// MARK: Full screen

function showFullscreen(): void {
  if (fullscreenWindow && !fullscreenWindow.isDestroyed()) {
    if (headless) return;
    fullscreenWindow.show();
    fullscreenWindow.setFullScreen(true);
    fullscreenWindow.focus();
    return;
  }
  const win = new BrowserWindow({
    width: 1440,
    height: 900,
    fullscreen: !headless,
    show: !headless,
    title: "Bike App – Vollbild",
    backgroundColor: "#0B0D12",
    icon: iconFile,
    autoHideMenuBar: true,
    webPreferences: webPreferences(),
  });
  win.setMenuBarVisibility(false);
  win.loadFile(rendererFile, { query: { view: "fullscreen" } });
  // Left full screen with Esc or the window manager: back to the bar.
  win.on("leave-full-screen", () => {
    if (!closingFullscreen) model.setDisplayMode("bar");
  });
  win.on("closed", () => {
    fullscreenWindow = null;
    if (!closingFullscreen && model.isRiding) model.setDisplayMode("bar");
  });
  fullscreenWindow = win;
}

function closeFullscreen(): void {
  const win = fullscreenWindow;
  if (!win || win.isDestroyed()) return;
  closingFullscreen = true;
  fullscreenWindow = null;
  win.destroy();
  closingFullscreen = false;
}

const coordinator = {
  rideDidStart(): void {
    coordinator.displayModeChanged();
    startRideUpdates();
  },
  rideDidFinish(): void {
    hideOverlay();
    closeFullscreen();
    send("ride", null);
    if (!smokeDirectory) showMainWindow();
  },
  displayModeChanged(): void {
    if (!model.isRiding) return;
    if (model.displayMode === "bar") {
      closeFullscreen();
      if (model.overlayVisible) showOverlay();
    } else {
      hideOverlay();
      showFullscreen();
    }
  },
  overlayStateChanged(): void {
    overlayWindow?.setIgnoreMouseEvents(model.clickThrough);
    if (!model.isRiding || model.displayMode !== "bar") return;
    if (model.overlayVisible) showOverlay();
    else hideOverlay();
  },
};

// MARK: State updates for the windows

let statePending = false;
let rideTimer: ReturnType<typeof setInterval> | null = null;
let lastControlRow: boolean | null = null;

function pushState(): void {
  if (statePending) return;
  statePending = true;
  setTimeout(() => {
    statePending = false;
    send("state", model.state());
    updateTray();
    if (lastControlRow !== model.s.showControlRow) {
      lastControlRow = model.s.showControlRow;
      applyOverlayLayout();
    }
  }, 30);
}

function pushRide(): void {
  send("ride", model.rideState());
}

function startRideUpdates(): void {
  if (rideTimer) return;
  rideTimer = setInterval(() => {
    if (model.isRiding) {
      pushRide();
    } else if (rideTimer) {
      clearInterval(rideTimer);
      rideTimer = null;
    }
  }, 250);
  pushRide();
}

// MARK: Actions from the windows

type Handler = (...args: any[]) => unknown;

const actions: Record<string, Handler> = {
  "settings.set": (patch: Partial<Settings>) => model.settings.set(patch),
  "ride.start": (request: StartRequest) => model.start(request),
  "ride.stop": () => model.stopRide(),
  "ride.discard": () => model.discardRide(),
  "ride.togglePause": () => model.togglePause(),
  "ride.shift": (direction: "up" | "down") => model.shift(direction),
  "ride.adjustGoal": (steps: number) => model.adjustGoal(steps),
  "ride.setGoal": (goal) => model.setGoal(goal),
  "ride.endTestEffort": () => model.endTestEffort(),
  "display.set": (mode) => model.setDisplayMode(mode),
  "display.toggle": () => model.toggleDisplayMode(),
  "overlay.toggle": () => model.toggleOverlay(),
  "overlay.clickThrough": () => model.toggleClickThrough(),
  "overlay.dragStart": () => {
    if (overlayWindow) dragStart = overlayWindow.getBounds();
  },
  "overlay.dragMove": (dx: number, dy: number) => {
    if (!overlayWindow || !dragStart) return;
    overlayWindow.setBounds({ x: Math.round(dragStart.x + dx), y: Math.round(dragStart.y + dy), width: dragStart.width, height: dragStart.height });
  },
  "overlay.resize": (dx: number, dy: number) => {
    if (!overlayWindow || !dragStart) return;
    const aspect = dragStart.width / dragStart.height;
    const delta = Math.abs(dx) >= Math.abs(dy * aspect) ? dx : dy * aspect;
    const width = Math.round(Math.min(OVERLAY.maxWidth, Math.max(OVERLAY.minWidth, dragStart.width + delta)));
    // Keep the top-left corner in place.
    overlayWindow.setBounds({ x: dragStart.x, y: dragStart.y, width, height: Math.round(width / aspect) });
  },
  "overlay.dragEnd": () => {
    dragStart = null;
    saveOverlayBounds();
  },
  "ble.scan": (seconds: number) => model.ble.startScan(seconds),
  "ble.stopScan": () => {
    model.ble.stopScan();
    model.ble.stopLearningButtons();
  },
  "ble.assign": (id: string, role) => model.ble.assign(id, role),
  "ble.unassign": (role) => model.ble.unassign(role),
  "ble.demo": (enabled: boolean) => model.ble.setDemoMode(enabled),
  "ble.learnStart": () => model.ble.startLearningButtons(),
  "ble.learnStop": () => model.ble.stopLearningButtons(),
  "ble.learnReset": () => model.ble.resetButtonMapping(),
  "intervals.refresh": () => model.intervals.refreshAll(),
  "intervals.saveKey": (key: string) => model.saveAPIKey(key),
  "intervals.clearKey": () => model.intervals.setAPIKey(""),
  "rides.upload": (id: string) => model.uploadStored(id),
  "rides.delete": (id: string) => model.deleteRide(id),
  "rides.sync": () => model.syncPending(),
  "rides.import": async () => {
    const result = await dialog.showOpenDialog({ title: "FIT-Dateien importieren", properties: ["openFile", "multiSelections"], filters: [{ name: "FIT", extensions: ["fit"] }] });
    if (result.canceled || result.filePaths.length === 0) return null;
    return model.importFITs(result.filePaths);
  },
  "rides.export": async (id: string) => {
    const data = model.rides.fit(id);
    if (!data) return false;
    const result = await dialog.showSaveDialog({ title: "FIT exportieren", defaultPath: path.join(app.getPath("downloads"), id), filters: [{ name: "FIT", extensions: ["fit"] }] });
    if (result.canceled || !result.filePath) return false;
    fs.writeFileSync(result.filePath, data);
    return true;
  },
  "rides.openFolder": () => {
    fs.mkdirSync(model.rides.directory, { recursive: true });
    return shell.openPath(model.rides.directory);
  },
  "finished.upload": () => model.uploadFinished(),
  "ftp.apply": (transfer: boolean) => model.applyFTP(transfer),
  "ftp.transfer": () => model.transferFTP(),
  "ftp.undo": () => model.undoFTP(),
  "workouts.save": (workout: CustomWorkout) => model.saveWorkout(workout),
  "workouts.delete": (id: string) => model.deleteWorkout(id),
  "workouts.duplicate": (id: string) => model.duplicateWorkout(id),
  "music.playPause": () => model.music.playPause(),
  "music.next": () => model.music.next(),
  "music.previous": () => model.music.previous(),
  "music.launch": () => model.music.launchAndPlay(),
  "clipboard.write": (text: string) => clipboard.writeText(String(text)),
  "open.external": (url: string) => openExternal(String(url)),
  "window.showMain": () => showMainWindow(),
  "shortcuts.installGnome": () => installGnomeShortcuts(),
};

/** Actions that can also be triggered from outside: `bike-app --action=pause` (e.g. bound to a desktop shortcut). */
const externalActions: Record<string, () => void> = {
  "shift-up": () => model.shift("up"),
  "shift-down": () => model.shift("down"),
  pause: () => model.togglePause(),
  "toggle-display": () => {
    if (model.isRiding) model.toggleDisplayMode();
  },
  "toggle-bar": () => model.toggleOverlay(),
  "toggle-clickthrough": () => model.toggleClickThrough(),
  stop: () => model.stopRide(),
};

function registerShortcuts(): void {
  // GNOME system shortcuts take over when the user set them up.
  if (gnomeShortcutsInstalled()) {
    model.shortcutsActive = true;
    return;
  }
  const bind = (accelerator: string, action: () => void) => {
    try {
      return globalShortcut.register(accelerator, () => {
        action();
        pushRide();
      });
    } catch {
      return false;
    }
  };
  // Ctrl+Alt+Up/Down switch workspaces on GNOME, so Page Up/Down are the main keys for shifting.
  const up = bind("Control+Alt+PageUp", externalActions["shift-up"]);
  bind("Control+Alt+PageDown", externalActions["shift-down"]);
  bind("Control+Alt+Up", externalActions["shift-up"]);
  bind("Control+Alt+Down", externalActions["shift-down"]);
  const pause = bind("Control+Alt+P", externalActions.pause);
  bind("Control+Alt+F", externalActions["toggle-display"]);
  bind("Control+Alt+B", externalActions["toggle-bar"]);
  bind("Control+Alt+K", externalActions["toggle-clickthrough"]);
  model.shortcutsActive = up && pause;
}


// MARK: System shortcuts (GNOME)

const systemShortcuts: [string, string, string][] = [
  ["Bike App: schwerer", "shift-up", "<Control><Alt>Page_Up"],
  ["Bike App: leichter", "shift-down", "<Control><Alt>Page_Down"],
  ["Bike App: Pause", "pause", "<Control><Alt>p"],
  ["Bike App: Leiste/Vollbild", "toggle-display", "<Control><Alt>f"],
  ["Bike App: Leiste ein/aus", "toggle-bar", "<Control><Alt>b"],
  ["Bike App: durchklickbar", "toggle-clickthrough", "<Control><Alt>k"],
];

const gnomeSchema = "org.gnome.settings-daemon.plugins.media-keys";
const gnomeBase = "/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/";

/**
 * Registers the shortcuts as GNOME custom shortcuts that call `bike-app --action=…`.
 * They work in every app, also when a Wayland-native browser has the focus.
 */
function installGnomeShortcuts(): string {
  if (!isLinux) return "Nur unter Linux verfügbar.";
  const command = fs.existsSync("/usr/bin/bike-app") ? "/usr/bin/bike-app" : process.execPath;
  try {
    const gsettings = (...args: string[]) => execFileSync("gsettings", args, { encoding: "utf8" }).trim();
    const current = gsettings("get", gnomeSchema, "custom-keybindings");
    const existing = (current.match(/'[^']*'/g) ?? []).map((x) => x.slice(1, -1)).filter((x) => !x.includes("/bikeapp-"));
    const ours = systemShortcuts.map((_, i) => `${gnomeBase}bikeapp-${i}/`);
    for (const [i, [name, action, binding]] of systemShortcuts.entries()) {
      const schema = `${gnomeSchema}.custom-keybinding:${ours[i]}`;
      gsettings("set", schema, "name", name);
      gsettings("set", schema, "command", `'${command}' --action=${action}`);
      gsettings("set", schema, "binding", binding);
    }
    gsettings("set", gnomeSchema, "custom-keybindings", `[${[...existing, ...ours].map((x) => `'${x}'`).join(", ")}]`);
    // The app's own grabs would clash with the system shortcuts.
    globalShortcut.unregisterAll();
    model.shortcutsActive = true;
    model.settings.set({});
    return "Eingerichtet: Die Kürzel stehen jetzt in den GNOME-Einstellungen unter Tastatur › Eigene Tastenkürzel.";
  } catch {
    return "Das ging nicht automatisch (kein GNOME?). Lege die Kürzel in den Systemeinstellungen von Hand an, siehe README.";
  }
}

function gnomeShortcutsInstalled(): boolean {
  if (!isLinux) return false;
  try {
    return execFileSync("gsettings", ["get", gnomeSchema, "custom-keybindings"], { encoding: "utf8" }).includes("/bikeapp-");
  } catch {
    return false;
  }
}

// MARK: Tray

let traySignature = "";

function updateTray(): void {
  if (!tray) return;
  const ride = model.rideState();
  const signature = JSON.stringify([ride?.name, ride?.phase, ride?.goalLabel, ride?.canChangeGoal, model.displayMode, model.overlayVisible, model.clickThrough, model.music.state.running, model.music.state.playing]);
  if (signature === traySignature) return;
  traySignature = signature;
  const items: Electron.MenuItemConstructorOptions[] = [];
  if (ride) {
    items.push({ label: ride.name, enabled: false });
    items.push({ label: ride.phase === "paused" ? `Weiter (${SHORTCUT_PREFIX}+P)` : `Pause (${SHORTCUT_PREFIX}+P)`, click: () => model.togglePause() });
    if (ride.canChangeGoal) {
      const unit = ride.goal.kind === "distance" ? "km" : "min";
      items.push({ label: `Ziel: ${ride.goalLabel}`, enabled: false });
      items.push({ label: `Ziel +5 ${unit}`, click: () => model.adjustGoal(1) });
      items.push({ label: `Ziel −5 ${unit}`, click: () => model.adjustGoal(-1) });
    }
    items.push({ label: "Fahrt beenden", click: () => model.stopRide() }, { type: "separator" });
    if (model.music.state.running) {
      items.push({ label: model.music.state.playing ? "Musik pausieren" : "Musik abspielen", click: () => model.music.playPause() });
      items.push({ label: "Nächster Titel", click: () => model.music.next() }, { type: "separator" });
    }
    items.push({ label: model.displayMode === "bar" ? `Vollbild (${SHORTCUT_PREFIX}+F)` : `Leiste (${SHORTCUT_PREFIX}+F)`, click: () => model.toggleDisplayMode() });
    items.push({ label: model.overlayVisible ? `Leiste ausblenden (${SHORTCUT_PREFIX}+B)` : `Leiste einblenden (${SHORTCUT_PREFIX}+B)`, click: () => model.toggleOverlay() });
    items.push({ label: `Leiste durchklickbar (${SHORTCUT_PREFIX}+K)`, type: "checkbox", checked: model.clickThrough, click: () => model.toggleClickThrough() });
    items.push({ type: "separator" });
  }
  items.push({ label: "Bike App öffnen", click: () => showMainWindow() }, { type: "separator" }, { label: "Beenden", click: () => app.quit() });
  tray.setContextMenu(Menu.buildFromTemplate(items));
  tray.setToolTip(ride ? `Bike App – ${ride.watts} W` : "Bike App");
}

function createTray(): void {
  try {
    const image = nativeImage.createFromPath(iconFile).resize({ width: 22, height: 22 });
    tray = new Tray(image);
    tray.on("click", () => showMainWindow());
    updateTray();
  } catch (error) {
    console.error("Tray-Symbol nicht verfügbar:", error);
  }
}

// MARK: Demo ride and smoke test

function startDemoRide(): void {
  model.ble.startTemporaryDemo();
  model.startRide({
    name: "Demo-Fahrt",
    courseTitle: "Hügelig · −5,0 … +7 %",
    gradeRange: { min: -5, max: 7 },
    seed: 502,
    goal: { kind: "distance", meters: 5000 },
    workout: null,
    workoutMode: "ergOffset",
    presetTitle: "Hügelig",
    test: null,
  });
}

const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

/** Runs the app once without hardware and checks that a ride is recorded, saved and readable. */
async function runSmokeTest(directory: string): Promise<void> {
  const problems: string[] = [];
  const check = (ok: boolean, text: string) => {
    if (!ok) problems.push(text);
  };
  const capture = async (win: BrowserWindow | null, name: string) => {
    if (!win || win.isDestroyed()) return check(false, `Fenster für ${name} fehlt`);
    const image = await win.webContents.capturePage();
    fs.writeFileSync(path.join(directory, `${name}.png`), image.toPNG());
    check(!image.isEmpty(), `${name}: leeres Bild`);
  };
  const consoleErrors: string[] = [];
  const watch = (win: BrowserWindow | null) =>
    win?.webContents.on("console-message", (event: any, legacyLevel: unknown, legacyMessage: unknown) => {
      const level = event?.level ?? legacyLevel;
      const message = event?.message ?? legacyMessage;
      if (level === 3 || level === "error") consoleErrors.push(String(message));
    });
  let report: Record<string, unknown> = {};
  try {
    fs.mkdirSync(directory, { recursive: true });
    watch(mainWindow);
    mainWindow?.webContents.reload();
    await sleep(3000);
    const startText: string = (await mainWindow?.webContents.executeJavaScript("document.body.innerText")) ?? "";
    const pageErrors: string = (await mainWindow?.webContents.executeJavaScript("JSON.stringify(window.__bikeErrors)")) ?? "";
    check(startText.includes("Los geht's"), `Startansicht leer: ${startText.slice(0, 120)} ${pageErrors.slice(0, 1500)}`);
    await capture(mainWindow, "1-start");

    startDemoRide();
    watch(overlayWindow);
    await sleep(9000);
    const engine = model.engine;
    check(engine != null && engine.phase === "riding", `Fahrt läuft nicht (Phase ${engine?.phase})`);
    check((engine?.distance ?? 0) > 5, `keine Distanz (${engine?.distance})`);
    check((engine?.recorder.samples.length ?? 0) >= 5, `zu wenige Messpunkte (${engine?.recorder.samples.length})`);
    check((engine?.power3s ?? 0) > 50, `keine Leistung (${engine?.power3s})`);
    model.shift("up");
    pushRide();
    await sleep(600);
    await capture(overlayWindow, "2-leiste");
    await capture(mainWindow, "3-fahrt");

    model.setDisplayMode("fullscreen");
    watch(fullscreenWindow);
    await sleep(3000);
    await capture(fullscreenWindow, "4-vollbild");
    const recorded = engine?.recorder.samples.length ?? 0;

    model.stopRide();
    await sleep(1500);
    check(model.finished != null, "keine Zusammenfassung nach der Fahrt");
    check(model.history.length === 1, `Historie hat ${model.history.length} Einträge`);
    const entry = model.history[0];
    const fit = entry ? model.rides.fit(entry.id) : null;
    check(fit != null, "FIT-Datei fehlt");
    const decoded = fit ? rideFromFIT(fit) : null;
    check(decoded != null && decoded.samples.length >= recorded, `FIT hat ${decoded?.samples.length} Punkte, aufgezeichnet ${recorded}`);
    await capture(mainWindow, "5-zusammenfassung");

    model.discardRide();
    send("nav", "history");
    await sleep(1200);
    await capture(mainWindow, "6-historie");

    // A workout in ERG mode, shown in the bar and in full screen.
    model.ble.startTemporaryDemo();
    const workoutId = model.saveWorkout({ id: "SMOKE", name: "Sweet Spot 3 × 10", notes: "", modified: "", blocks: (await import("../core/workout")).Custom.templates()[1].blocks });
    check(model.start({ kind: "workout", seed: 7, workoutId }), "Workout ließ sich nicht starten");
    await sleep(600);
    model.engine?.applyPreview({ distance: 14_200, movingTime: 1340, power: 228, cadence: 91, heartRate: 158, gear: 12 });
    pushRide();
    await sleep(700);
    await capture(overlayWindow, "7-leiste-workout");
    model.setDisplayMode("fullscreen");
    await sleep(2500);
    model.engine?.applyPreview({ distance: 14_200, movingTime: 1340, power: 228, cadence: 91, heartRate: 158, gear: 12 });
    pushRide();
    await sleep(700);
    await capture(fullscreenWindow, "8-vollbild-workout");
    model.stopRide();
    await sleep(800);

    check(consoleErrors.length === 0, `Fehler in den Fenstern: ${consoleErrors.slice(0, 5).join(" | ")}`);
    report = {
      platform: `${process.platform} ${os.release()}`,
      electron: process.versions.electron,
      sessionType: process.env.XDG_SESSION_TYPE ?? null,
      bluetooth: { adapter: model.ble.adapter, message: model.ble.adapterMessage },
      recordedSamples: recorded,
      fitSamples: decoded?.samples.length ?? 0,
      distance: entry?.distance ?? 0,
      avgPower: entry?.summary?.avgPower ?? 0,
      shortcutsActive: model.shortcutsActive,
    };
  } catch (error) {
    problems.push(`Ausnahme: ${(error as Error)?.stack ?? error}`);
  }
  fs.writeFileSync(path.join(directory, "result.json"), JSON.stringify({ ok: problems.length === 0, problems, ...report }, null, 2));
  console.log(problems.length === 0 ? "SMOKE TEST OK" : `SMOKE TEST FEHLGESCHLAGEN:\n${problems.join("\n")}`);
  quitting = true;
  app.exit(problems.length === 0 ? 0 : 1);
}

// MARK: Start

function handleArguments(argv: string[]): void {
  const action = argv.find((a) => a.startsWith("--action="))?.slice(9);
  if (action && externalActions[action]) {
    externalActions[action]();
    pushRide();
    pushState();
  } else if (!action) {
    showMainWindow();
  }
}

if (!smokeDirectory && !app.requestSingleInstanceLock()) {
  app.quit();
} else {
  app.on("second-instance", (_event, argv) => handleArguments(argv));

  app.whenReady().then(() => {
    const directory = dataDirectory();
    Menu.setApplicationMenu(null);
    model = new AppModel({
      dataDirectory: directory,
      transport: new BlueZTransport(),
      apiKey: smokeDirectory ? "" : readAPIKey(directory),
      storeKey: (key) => storeAPIKey(directory, key),
      ephemeralSettings: smokeDirectory != null,
      version: app.getVersion(),
      shortcutLabel: `${SHORTCUT_PREFIX}+P`,
    });
    model.coordinator = coordinator;
    model.onStateChange = pushState;
    model.onHistoryChange = () => send("history", model.history);

    ipcMain.handle("bike:init", () => ({ state: model.state(), ride: model.rideState(), history: model.history }));
    ipcMain.handle("bike:action", async (_event, name: string, ...args: unknown[]) => {
      const handler = actions[name];
      if (!handler) throw new Error(`Unbekannte Aktion: ${name}`);
      const result = await handler(...args);
      pushRide();
      return result ?? null;
    });

    createMainWindow();
    registerShortcuts();
    createTray();
    model.bootstrap();

    if (smokeDirectory) void runSmokeTest(path.resolve(smokeDirectory));
    else if (hasFlag("demo-ride")) startDemoRide();
    else if (argValue("action")) handleArguments(process.argv);
  });

  app.on("activate", () => showMainWindow());

  app.on("window-all-closed", () => {
    if (!model?.isRiding) app.quit();
  });

  app.on("before-quit", () => {
    quitting = true;
    // A running ride is saved before the app goes away.
    if (model?.isRiding) model.stopRide();
    model?.settings.flush();
  });

  app.on("will-quit", () => globalShortcut.unregisterAll());
}
