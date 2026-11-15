// Bluetooth LE on Linux: talks to BlueZ over the D-Bus system bus (no native modules).
import dbus from "dbus-next";
import { ManufacturerData } from "../../core/ble";
import { AdapterState } from "../../core/state";

const { Message, Variant } = dbus;

const BLUEZ = "org.bluez";
const OM = "org.freedesktop.DBus.ObjectManager";
const PROPS = "org.freedesktop.DBus.Properties";
const ADAPTER = "org.bluez.Adapter1";
const DEVICE = "org.bluez.Device1";
const SERVICE = "org.bluez.GattService1";
const CHAR = "org.bluez.GattCharacteristic1";

export interface Advertisement {
  /** Bluetooth address, e.g. "AA:BB:CC:DD:EE:FF". */
  id: string;
  name: string;
  rssi: number;
  services: string[];
  manufacturerData: ManufacturerData;
}

export interface Characteristic {
  uuid: string;
  service: string;
  flags: string[];
}

export interface TransportEvents {
  adapterState(state: AdapterState, message: string | null): void;
  discovered(ad: Advertisement): void;
  connected(id: string, name: string | null, characteristics: Characteristic[]): void;
  disconnected(id: string): void;
  value(id: string, uuid: string, bytes: Uint8Array): void;
  scanning(active: boolean): void;
}

/** What the device manager needs from a Bluetooth stack. */
export interface BleTransport {
  start(events: TransportEvents): Promise<void>;
  /** Scans because the user asked for it (device list is open). */
  setUserScan(active: boolean): void;
  /** Keeps trying to connect until `release` is called. */
  want(id: string): void;
  release(id: string): void;
  write(id: string, uuid: string, bytes: number[], withResponse: boolean): Promise<void>;
  read(id: string, uuid: string): Promise<Uint8Array>;
  subscribe(id: string, uuid: string): Promise<void>;
}

type Props = Record<string, any>;

function unwrap(value: any): any {
  if (value instanceof Variant) return unwrap(value.value);
  if (Buffer.isBuffer(value)) return value;
  if (Array.isArray(value)) return value.map(unwrap);
  if (value && typeof value === "object") {
    const out: Props = {};
    for (const [k, v] of Object.entries(value)) out[k] = unwrap(v);
    return out;
  }
  return value;
}

const devicePathOf = (path: string) => path.split("/").slice(0, 5).join("/");

export class BlueZTransport implements BleTransport {
  private bus: dbus.MessageBus | null = null;
  private events!: TransportEvents;
  /** path -> interface -> properties */
  private objects = new Map<string, Record<string, Props>>();
  private adapterPath: string | null = null;
  private wanted = new Set<string>();
  private connecting = new Set<string>();
  /** Devices whose services are resolved and announced. */
  private active = new Map<string, Map<string, string>>();
  private retryTimers = new Map<string, ReturnType<typeof setTimeout>>();
  private userScan = false;
  private discovering = false;

  async start(events: TransportEvents): Promise<void> {
    this.events = events;
    if (process.platform !== "linux") {
      events.adapterState("unavailable", "Bluetooth wird nur unter Linux unterstützt (BlueZ)");
      return;
    }
    let slow: ReturnType<typeof setTimeout> | undefined;
    try {
      const bus = dbus.systemBus();
      this.bus = bus;
      bus.on("error", (error: Error) => {
        console.error("D-Bus:", error.message);
        this.events.adapterState("unavailable", "Keine Verbindung zum System-Bus");
      });
      bus.on("message", (msg: dbus.Message) => this.onMessage(msg));
      // An inactive bluetooth.service can leave the first call waiting for a long time.
      slow = setTimeout(() => events.adapterState("unavailable", "Bluetooth antwortet nicht – läuft bluetooth.service?"), 6000);
      await this.call("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "AddMatch", "s", ["type='signal',sender='org.bluez'"]);
      const reply = await this.call(BLUEZ, "/", OM, "GetManagedObjects");
      clearTimeout(slow);
      const managed = unwrap(reply.body[0]) as Record<string, Record<string, Props>>;
      for (const [path, interfaces] of Object.entries(managed)) this.objects.set(path, interfaces);
      this.pickAdapter();
      for (const path of this.objects.keys()) this.deviceChanged(path, true);
    } catch (error) {
      clearTimeout(slow);
      const text = String((error as Error)?.message ?? error);
      events.adapterState("unavailable", text.includes("ServiceUnknown") || text.includes("org.bluez") ? "BlueZ läuft nicht (sudo systemctl start bluetooth)" : `Bluetooth nicht erreichbar: ${text}`);
    }
  }

  // MARK: D-Bus helpers

  private async call(destination: string, path: string, iface: string, member: string, signature?: string, body?: any[]): Promise<dbus.Message> {
    if (!this.bus) throw new Error("kein D-Bus");
    const reply = await this.bus.call(new Message({ destination, path, interface: iface, member, signature, body }));
    if (!reply) throw new Error("keine Antwort");
    return reply;
  }

  private props(path: string, iface: string): Props | undefined {
    return this.objects.get(path)?.[iface];
  }

  private pathFor(id: string): string | null {
    for (const [path, interfaces] of this.objects) {
      if (interfaces[DEVICE]?.Address === id) return path;
    }
    return null;
  }

  private idFor(path: string): string | null {
    return this.props(path, DEVICE)?.Address ?? null;
  }

  // MARK: Signals

  private onMessage(msg: dbus.Message): void {
    if (msg.type !== dbus.MessageType.SIGNAL || !msg.path) return;
    try {
      if (msg.interface === OM && msg.member === "InterfacesAdded") {
        const [path, interfaces] = msg.body as [string, Record<string, Props>];
        const merged = { ...(this.objects.get(path) ?? {}), ...unwrap(interfaces) };
        this.objects.set(path, merged);
        if (merged[ADAPTER] && !this.adapterPath) this.pickAdapter();
        if (merged[DEVICE]) this.deviceChanged(path, true);
      } else if (msg.interface === OM && msg.member === "InterfacesRemoved") {
        const [path, interfaces] = msg.body as [string, string[]];
        const existing = this.objects.get(path);
        if (!existing) return;
        if (interfaces.includes(DEVICE)) {
          const id = existing[DEVICE]?.Address;
          if (id) this.handleDisconnect(id);
        }
        for (const name of interfaces) delete existing[name];
        if (Object.keys(existing).length === 0) this.objects.delete(path);
        if (path === this.adapterPath && interfaces.includes(ADAPTER)) {
          this.adapterPath = null;
          this.discovering = false;
          this.pickAdapter();
        }
      } else if (msg.interface === PROPS && msg.member === "PropertiesChanged") {
        const [iface, changedRaw] = msg.body as [string, Props];
        const changed = unwrap(changedRaw) as Props;
        const object = this.objects.get(msg.path) ?? {};
        object[iface] = { ...(object[iface] ?? {}), ...changed };
        this.objects.set(msg.path, object);
        if (iface === CHAR && "Value" in changed) {
          const id = this.idFor(devicePathOf(msg.path));
          const uuid = object[CHAR]?.UUID;
          if (id && uuid && this.active.has(id)) this.events.value(id, String(uuid).toLowerCase(), new Uint8Array(changed.Value));
        } else if (iface === DEVICE) {
          this.deviceChanged(msg.path, "RSSI" in changed || "ManufacturerData" in changed, changed);
        } else if (iface === ADAPTER && msg.path === this.adapterPath) {
          if ("Powered" in changed) this.adapterChanged();
          if ("Discovering" in changed) {
            this.discovering = !!changed.Discovering;
            this.events.scanning(this.discovering);
            if (!this.discovering) this.updateScan();
          }
        }
      }
    } catch (error) {
      console.error("BlueZ-Signal:", error);
    }
  }

  private pickAdapter(): void {
    for (const [path, interfaces] of this.objects) {
      if (interfaces[ADAPTER]) {
        this.adapterPath = path;
        break;
      }
    }
    this.adapterChanged();
  }

  private adapterChanged(): void {
    if (!this.adapterPath) {
      this.events.adapterState("unavailable", "Kein Bluetooth-Adapter gefunden");
      return;
    }
    const adapter = this.props(this.adapterPath, ADAPTER) ?? {};
    if (adapter.Powered) {
      this.events.adapterState("poweredOn", null);
      this.updateScan();
      for (const id of this.wanted) this.tryConnect(id);
    } else {
      this.events.adapterState("poweredOff", "Bluetooth aus");
    }
  }

  private deviceChanged(path: string, advertising: boolean, changed?: Props): void {
    const device = this.props(path, DEVICE);
    if (!device?.Address) return;
    const id = device.Address as string;
    if (advertising && (device.RSSI != null || device.Connected)) {
      const manufacturerData: ManufacturerData = {};
      for (const [company, payload] of Object.entries(device.ManufacturerData ?? {})) {
        manufacturerData[Number(company)] = Array.from(payload as Buffer);
      }
      this.events.discovered({
        id,
        name: device.Name ?? device.Alias ?? "Unbekannt",
        rssi: typeof device.RSSI === "number" ? device.RSSI : -100,
        services: (device.UUIDs ?? []).map((u: string) => u.toLowerCase()),
        manufacturerData,
      });
    }
    if (changed && changed.Connected === false) this.handleDisconnect(id);
    if (!this.wanted.has(id)) return;
    if (device.Connected && device.ServicesResolved) this.finishConnect(id, path);
    else if (!device.Connected && !this.retryTimers.has(id)) this.tryConnect(id);
  }

  // MARK: Scanning

  setUserScan(active: boolean): void {
    this.userScan = active;
    this.updateScan();
  }

  /** Discovery stays on while the user scans or a wanted device is not connected (BlueZ forgets unseen devices otherwise). */
  private updateScan(): void {
    const adapter = this.adapterPath;
    if (!adapter || !this.props(adapter, ADAPTER)?.Powered) return;
    const needed = this.userScan || [...this.wanted].some((id) => !this.active.has(id));
    if (needed && !this.discovering) {
      this.discovering = true;
      this.call(BLUEZ, adapter, ADAPTER, "SetDiscoveryFilter", "a{sv}", [{ Transport: new Variant("s", "le") }])
        .catch(() => undefined)
        .then(() => this.call(BLUEZ, adapter, ADAPTER, "StartDiscovery"))
        .then(() => this.events.scanning(true))
        .catch((error) => {
          const text = String(error?.message ?? error);
          if (!text.includes("InProgress")) {
            this.discovering = false;
            console.error("StartDiscovery:", text);
          }
        });
    } else if (!needed && this.discovering) {
      this.discovering = false;
      this.call(BLUEZ, adapter, ADAPTER, "StopDiscovery").catch(() => undefined);
      this.events.scanning(false);
    }
  }

  // MARK: Connections

  want(id: string): void {
    this.wanted.add(id);
    this.updateScan();
    this.tryConnect(id);
  }

  release(id: string): void {
    this.wanted.delete(id);
    const timer = this.retryTimers.get(id);
    if (timer) clearTimeout(timer);
    this.retryTimers.delete(id);
    const path = this.pathFor(id);
    const wasActive = this.active.delete(id);
    if (path && (wasActive || this.props(path, DEVICE)?.Connected)) {
      this.call(BLUEZ, path, DEVICE, "Disconnect").catch(() => undefined);
    }
    this.updateScan();
  }

  private scheduleRetry(id: string, delay: number): void {
    if (!this.wanted.has(id) || this.retryTimers.has(id)) return;
    this.retryTimers.set(
      id,
      setTimeout(() => {
        this.retryTimers.delete(id);
        this.tryConnect(id);
      }, delay),
    );
  }

  private tryConnect(id: string): void {
    if (!this.wanted.has(id) || this.connecting.has(id) || this.active.has(id)) return;
    if (!this.adapterPath || !this.props(this.adapterPath, ADAPTER)?.Powered) return;
    const path = this.pathFor(id);
    // Not seen yet: discovery is running and `deviceChanged` comes back here.
    if (!path) return;
    const device = this.props(path, DEVICE) ?? {};
    if (device.Connected) {
      if (device.ServicesResolved) this.finishConnect(id, path);
      return;
    }
    this.connecting.add(id);
    this.call(BLUEZ, path, DEVICE, "Connect")
      .then(() => {
        this.connecting.delete(id);
        const now = this.props(path, DEVICE) ?? {};
        if (now.Connected && now.ServicesResolved) this.finishConnect(id, path);
      })
      .catch(() => {
        this.connecting.delete(id);
        this.scheduleRetry(id, 4000);
      });
  }

  private finishConnect(id: string, path: string): void {
    if (this.active.has(id) || !this.wanted.has(id)) return;
    const characteristics: Characteristic[] = [];
    const paths = new Map<string, string>();
    for (const [objectPath, interfaces] of this.objects) {
      const char = interfaces[CHAR];
      if (!char || !objectPath.startsWith(path + "/")) continue;
      const uuid = String(char.UUID).toLowerCase();
      const service = String(this.props(char.Service, SERVICE)?.UUID ?? "").toLowerCase();
      characteristics.push({ uuid, service, flags: char.Flags ?? [] });
      // Zwift characteristics may exist under two services; the first one wins.
      if (!paths.has(uuid)) paths.set(uuid, objectPath);
    }
    this.active.set(id, paths);
    this.updateScan();
    const device = this.props(path, DEVICE) ?? {};
    this.events.connected(id, device.Name ?? device.Alias ?? null, characteristics);
  }

  private handleDisconnect(id: string): void {
    this.connecting.delete(id);
    if (this.active.delete(id)) this.events.disconnected(id);
    this.updateScan();
    this.scheduleRetry(id, 2000);
  }

  private charPath(id: string, uuid: string): string {
    const path = this.active.get(id)?.get(uuid);
    if (!path) throw new Error(`Characteristic ${uuid} nicht vorhanden`);
    return path;
  }

  async write(id: string, uuid: string, bytes: number[], withResponse: boolean): Promise<void> {
    const options = { type: new Variant("s", withResponse ? "request" : "command") };
    await this.call(BLUEZ, this.charPath(id, uuid), CHAR, "WriteValue", "aya{sv}", [Buffer.from(bytes), options]);
  }

  async read(id: string, uuid: string): Promise<Uint8Array> {
    const reply = await this.call(BLUEZ, this.charPath(id, uuid), CHAR, "ReadValue", "a{sv}", [{}]);
    return new Uint8Array(reply.body[0] as Buffer);
  }

  async subscribe(id: string, uuid: string): Promise<void> {
    await this.call(BLUEZ, this.charPath(id, uuid), CHAR, "StartNotify");
  }
}
