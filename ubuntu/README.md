# Bike App für Ubuntu

Die Ubuntu-Version der Bike App für den Wahoo Kickr Core 2 (und Kickr Core) mit Zwift Cog und Zwift Click v1/v2. Sie kann dasselbe wie die Mac-App:

- schwebende Leiste über der Serie, alternativ Vollbild-Dashboard
- freie Fahrt mit zufälligem Höhenprofil, Workouts (eigene und von intervals.icu), FTP-Test
- virtuelle Gänge mit dem Click, Pause mit beiden Tasten
- Historie mit Diagrammen, Upload zu intervals.icu als FIT-Datei
- Spotify-Steuerung in der Leiste

Technisch ist sie eine Electron-App. Bluetooth läuft direkt über BlueZ (D-Bus), es gibt keine nativen Module.

## Installieren

Das Paket liegt unter **Releases** im GitHub-Repo, für amd64 (normale PCs) und arm64.

```bash
sudo apt install ./bike-app_0.1.0_amd64.deb
```

Danach ist „Bike App“ im App-Menü. Im Terminal startet sie mit `bike-app`.

Unterstützt sind Ubuntu 22.04 und 24.04. Bluetooth muss laufen (`bluetooth.service`, bei Ubuntu Standard). Spezielle Rechte braucht die App nicht: BlueZ erlaubt angemeldeten Nutzern Bluetooth LE.

Deinstallieren: `sudo apt remove bike-app`. Deine Fahrten bleiben dabei erhalten.

## Wo liegen die Daten?

| Was | Wo |
| --- | --- |
| Fahrten (FIT + Kennzahlen) | `~/.local/share/BikeApp/Rides` |
| Eigene Workouts | `~/.local/share/BikeApp/Workouts.json` |
| Einstellungen | `~/.local/share/BikeApp/settings.json` |
| intervals.icu-API-Key | verschlüsselt mit dem GNOME-Schlüsselbund bzw. KWallet (`secrets.json`) |

Die Dateien haben dasselbe Format wie auf dem Mac. Fahrten und Workouts kannst du von `~/Library/Application Support/BikeApp/` einfach herüberkopieren. Die App übernimmt beim nächsten Start auch lose FIT-Dateien aus dem `Rides`-Ordner.

## Unterschiede zum Mac

**Tastenkürzel.** Statt ⌃⌥ gilt Strg+Alt:

| Kürzel | Funktion |
| --- | --- |
| Strg+Alt+Bild↑ / Bild↓ | schalten (ohne Click) |
| Strg+Alt+P | Pause / weiter |
| Strg+Alt+F | Leiste ↔ Vollbild |
| Strg+Alt+B | Leiste ein / aus |
| Strg+Alt+K | Leiste durchklickbar |

Strg+Alt+↑/↓ wechselt bei GNOME die Arbeitsfläche, deshalb schaltet die App mit Bild↑/↓. Im Vollbild gehen auch ↑/↓, +/− und die Leertaste.

Unter Wayland (Standard bei Ubuntu) bekommt die App die Kürzel nur, wenn ein X11-Programm im Vordergrund ist. Läuft die Serie in Firefox oder Chrome, kommen sie nicht an. Abhilfe mit einem Klick: **Einstellungen › Anzeige › Als GNOME-Kürzel einrichten**. Die Kürzel stehen danach in den Systemeinstellungen unter *Tastatur › Eigene Tastenkürzel* und funktionieren überall. Sie rufen `bike-app --action=…` auf:

`shift-up`, `shift-down`, `pause`, `toggle-display`, `toggle-bar`, `toggle-clickthrough`, `stop`

So lassen sich die Aktionen auch in KDE oder anderen Desktops auf eigene Tasten legen.

**Leiste.** Damit die Leiste frei schweben und über anderen Fenstern bleiben kann, läuft die App über XWayland. Das Startmenü-Symbol erledigt das automatisch. Größe ändern geht über die rechte untere Ecke, verschieben durch Ziehen. Doppelklick wechselt ins Vollbild.

**Musik.** Die Steuerzeile spricht Spotify über MPRIS an. Andere Player oder eine Serie im Browser werden nicht pausiert.

**Menüleiste.** Statt des Menüleisten-Symbols gibt es ein Tray-Symbol. Bei GNOME braucht es dafür die Erweiterung „AppIndicator“, bei Ubuntu ist sie vorinstalliert.

## Entwickeln

Voraussetzung ist Node.js 22.

```bash
npm install
npm start            # App starten
npm run demo         # direkt eine Demo-Fahrt ohne Hardware
npm test             # Unit-Tests
npm run dist         # .deb für amd64 und arm64 nach release/
```

Selbsttest ohne Hardware: Er fährt eine Demo-Fahrt und ein Workout, beendet sie, prüft die FIT-Datei und speichert Bildschirmfotos aller Ansichten.

```bash
npm run build && npx electron . --smoke-test=smoke
```

Mit `--headless` bleiben die Fenster dabei unsichtbar.

### Aufbau

```
src/core/       Logik ohne Electron: Physik, Höhenprofil, Fahr-Engine, Workouts, FIT, Bluetooth-Protokolle
src/main/       Electron-Hauptprozess: Fenster, BlueZ, intervals.icu, Speicher, Spotify, Tastenkürzel
src/renderer/   Oberfläche (Preact): Hauptfenster, Leiste, Vollbild
test/           Unit-Tests
```

Bei jedem Push baut GitHub Actions die Pakete, installiert das amd64-Paket auf Ubuntu 24.04 und lässt dort den Selbsttest laufen. Ein Tag `v*` veröffentlicht die Pakete als Release.

## Bekannte Grenzen

- **Hardware:** Mit echtem Kickr und Click unter Ubuntu noch nicht getestet. Die Protokolle sind dieselben wie in der Mac-App, nur die Bluetooth-Schicht ist neu (BlueZ statt CoreBluetooth).
- **Leiste über Vollbild-Videos:** GNOME legt ein Video im echten Vollbild unter Umständen über die Leiste. Dann hilft es, das Video im maximierten Fenster abzuspielen oder in der App das Vollbild-Dashboard zu nutzen.
- **Click v2:** wie auf dem Mac. Die linke Hälfte braucht die Freigabe durch die Zwift-App, die Tasten lassen sich unter „Geräte verwalten…“ zuordnen.
