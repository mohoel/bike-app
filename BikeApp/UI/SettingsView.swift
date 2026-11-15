import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var apiKey = ""
    @State private var testState: String?
    @State private var importState: String?

    var body: some View {
        @Bindable var settings = model.settings
        TabView {
            Form {
                Section("Fahrer") {
                    numberField("Gewicht", value: $settings.riderWeight, unit: "kg")
                    numberField("Rad", value: $settings.bikeWeight, unit: "kg")
                    Stepper(value: $settings.ftp, in: 80...500, step: 5) {
                        Text("FTP (manuell): \(settings.ftp) W")
                    }
                    Toggle("FTP aus intervals.icu verwenden, wenn vorhanden", isOn: $settings.useIntervalsFTP)
                    if let ftp = model.intervals.athlete?.ftp {
                        Text("intervals.icu: \(ftp) W").foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("Fahrer", systemImage: "person") }

            Form {
                Section("Antrieb am Trainer") {
                    Stepper(value: $settings.chainring, in: 20...60) { Text("Kettenblatt: \(settings.chainring) Zähne") }
                    Stepper(value: $settings.cog, in: 10...20) { Text("Zwift Cog: \(settings.cog) Zähne") }
                    if settings.measuredTrainerRatio > 0 {
                        HStack {
                            Text("Gemessene Übersetzung: \(Fmt.decimal(settings.measuredTrainerRatio, 2))")
                            Spacer()
                            Button("Zurücksetzen") { settings.measuredTrainerRatio = 0 }
                        }
                    } else {
                        Text("Die tatsächliche Übersetzung wird bei der ersten Fahrt automatisch gemessen.")
                            .foregroundStyle(.secondary)
                    }
                }
                Section("Schalten und Widerstand") {
                    Stepper(value: $settings.startGear, in: 1...24) { Text("Startgang: \(settings.startGear)") }
                    VStack(alignment: .leading) {
                        Text("Trainer-Schwierigkeit: \(Int((settings.difficulty * 100).rounded())) %")
                        Slider(value: $settings.difficulty, in: 0...1, step: 0.05)
                        Text("Wie stark Steigungen am Trainer zu spüren sind. Zwift nutzt standardmäßig 50 %. Die angezeigte Geschwindigkeit rechnet immer mit der vollen Steigung.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Picker("Widerstand", selection: $settings.resistanceMode) {
                        ForEach(ResistanceMode.allCases) { Text($0.title).tag($0) }
                    }
                    Text(settings.resistanceMode.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("Trainer", systemImage: "bicycle") }

            Form {
                Section("Zugang") {
                    TextField("Athleten-ID", text: $settings.intervalsAthleteId, prompt: Text("0 = eigenes Konto"))
                    SecureField("API-Key", text: $apiKey, prompt: Text(model.intervals.isConfigured ? "gespeichert" : "aus Settings › Developer Settings"))
                    HStack {
                        Button("Speichern und testen") { saveAndTest() }
                            .disabled(apiKey.isEmpty && !model.intervals.isConfigured)
                        if model.intervals.isConfigured {
                            Button("Key löschen", role: .destructive) {
                                model.intervals.setAPIKey("")
                                testState = nil
                            }
                        }
                        Spacer()
                        if let testState { Text(testState).foregroundStyle(.secondary) }
                    }
                }
                Section("Upload") {
                    Toggle("Fahrten nach dem Ende automatisch hochladen", isOn: $settings.autoUpload)
                    Text("Jede Fahrt wird zuerst auf dem Mac gesichert. Fahrten ohne API-Key oder ohne Netz werden automatisch nachgeladen: beim Speichern des Keys, beim Start der App und wenn du zur App wechselst.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if model.pendingUploads > 0 {
                        HStack {
                            Text("\(model.pendingUploads) Fahrt(en) warten auf den Upload")
                            Spacer()
                            Button("Jetzt hochladen") { Task { await model.syncPending() } }
                                .disabled(!model.intervals.isConfigured)
                        }
                    }
                    HStack {
                        Button("FIT-Datei hochladen…") { importFIT() }
                        Button("Gesicherte Fahrten zeigen") {
                            try? FileManager.default.createDirectory(at: model.rides.directory, withIntermediateDirectories: true)
                            NSWorkspace.shared.open(model.rides.directory)
                        }
                        Spacer()
                        if let importState { Text(importState).foregroundStyle(.secondary) }
                    }
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("intervals.icu", systemImage: "chart.bar.xaxis") }

            Form {
                Section("Leiste") {
                    Toggle("Steuerzeile mit Spotify, Pause und Ziel", isOn: $settings.showControlRow)
                    VStack(alignment: .leading) {
                        Text("Deckkraft: \(Int((settings.overlayOpacity * 100).rounded())) %")
                        Slider(value: $settings.overlayOpacity, in: 0.3...0.95, step: 0.05)
                    }
                    Picker("Standardanzeige", selection: $settings.defaultDisplay) {
                        ForEach(DisplayMode.allCases) { Text($0.title).tag($0) }
                    }
                }
                Section("Testen") {
                    Toggle("Demo-Modus (Trainer, Puls und Kadenz simulieren)", isOn: Binding(get: { model.ble.isDemo }, set: { model.ble.setDemoMode($0) }))
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("Anzeige", systemImage: "rectangle.on.rectangle") }
        }
        .frame(width: 560, height: 520)
    }

    private func numberField(_ title: String, value: Binding<Double>, unit: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            TextField(title, value: value, format: .number.precision(.fractionLength(0...1)))
                .multilineTextAlignment(.trailing)
                .frame(width: 80)
                .labelsHidden()
            Text(unit).foregroundStyle(.secondary)
        }
    }

    private func saveAndTest() {
        let key = apiKey.isEmpty ? model.intervals.apiKey : apiKey
        apiKey = ""
        testState = "Teste…"
        Task {
            // Saving the key also uploads rides that waited for it.
            await model.saveAPIKey(key)
            switch model.intervals.state {
            case .loaded:
                let name = model.intervals.athlete?.name ?? "Konto"
                let waiting = model.pendingUploads
                testState = waiting > 0 ? "Verbunden: \(name) · \(waiting) Fahrt(en) noch offen" : "Verbunden: \(name)"
            case let .failed(message):
                testState = message
            default:
                testState = nil
            }
        }
    }

    private func importFIT() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: "fit") ?? .data]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        importState = "Lade hoch…"
        Task {
            var failed = 0
            for url in panel.urls {
                do { try await model.importFIT(from: url) } catch { failed += 1 }
            }
            importState = failed == 0 ? "Übernommen" : "\(failed) Datei(en) sind keine FIT-Dateien"
        }
    }
}
