import SwiftUI

/// The app's main window: setup before a ride, live status during, summary after.
struct MainWindowView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var tab: HomeTab = .setup

    enum HomeTab: String, CaseIterable, Identifiable {
        case setup
        case history

        var id: String { rawValue }
        var title: String { self == .setup ? "Neue Fahrt" : "Historie" }
    }

    var body: some View {
        Group {
            if let finished = model.finished {
                SummaryView(ride: finished)
            } else if model.isRiding, let engine = model.engine {
                RideStatusView(engine: engine)
            } else {
                VStack(spacing: 0) {
                    HStack(spacing: 8) {
                        ForEach(HomeTab.allCases) { t in
                            ChoiceChip(title: t == .history && !model.history.isEmpty ? "Historie · \(model.history.count)" : t.title, selected: tab == t) {
                                tab = t
                            }
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 28)
                    .padding(.top, 18)
                    if tab == .setup {
                        SetupView()
                    } else {
                        HistoryView()
                    }
                }
            }
        }
        .frame(minWidth: 760, minHeight: 640)
        .background(Theme.background)
        .environment(\.colorScheme, .dark)
        .preferredColorScheme(.dark)
        .onAppear {
            model.openMainWindow = { openWindow(id: "main") }
        }
    }
}

/// Card container used in the main window.
struct Card<Content: View>: View {
    let title: String?
    @ViewBuilder var content: Content

    init(_ title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let title {
                MetricLabel(text: title.uppercased(), size: 12)
            }
            content
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.tile))
    }
}

/// Selectable chip button.
struct ChoiceChip: View {
    let title: String
    let selected: Bool
    var tint: Color = Theme.accent
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Theme.text(14, .semibold))
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .frame(minHeight: 36)
                .foregroundStyle(selected ? Theme.onAccent : .white)
                .background(Capsule().fill(selected ? tint : Theme.chip))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - During the ride

struct RideStatusView: View {
    @Environment(AppModel.self) private var model
    let engine: RideEngine

    var body: some View {
        let display = RideDisplay(engine: engine, ftp: model.intervals.effectiveFTP, zones: model.intervals.zones)
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(engine.config.name)
                            .font(Theme.text(26, .bold))
                        Text(phaseText)
                            .font(Theme.text(15, .medium))
                            .foregroundStyle(Theme.secondary)
                    }
                    Spacer()
                    DeviceDots()
                }

                OverlayBar(display: display, s: 0.72, opacity: 0.9, useMaterial: false, showsGrip: false)

                HStack(spacing: 12) {
                    Button(engine.phase == .paused ? "Weiter" : "Pause") { model.togglePause() }
                        .keyboardShortcut(.space, modifiers: [])
                    Button("Fahrt beenden", role: .destructive) { model.stopRide() }
                    Spacer()
                    Picker("Anzeige", selection: Binding(get: { model.displayMode }, set: { model.setDisplayMode($0) })) {
                        ForEach(DisplayMode.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 220)
                }
                .controlSize(.large)

                if let outcome = model.ftpOutcome {
                    FTPResultCard(outcome: outcome)
                }

                if engine.canChangeGoal {
                    GoalEditor(engine: engine)
                }

                Card("Tastenkürzel") {
                    Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 8) {
                        shortcut("Click + / −", "Schwerer / leichter schalten")
                        shortcut("Click + und −", "Beide zusammen: Pause / weiter")
                        shortcut("⌃⌥ ↑ / ↓", "Schalten (ohne Click)")
                        shortcut("⌃⌥ P", "Pause / weiter")
                        shortcut("⌃⌥ F", "Leiste ↔ Vollbild")
                        shortcut("⌃⌥ B", "Leiste ein / aus")
                        shortcut("⌃⌥ K", "Leiste durchklickbar (für den Videoplayer)")
                    }
                    Text("Die Leiste lässt sich ziehen und über die rechte untere Ecke größer oder kleiner machen. Doppelklick wechselt ins Vollbild.")
                        .font(Theme.text(13, .regular))
                        .foregroundStyle(Theme.secondary)
                }
            }
            .padding(28)
        }
    }

    private var phaseText: String {
        switch engine.phase {
        case .waiting: return "Bereit – tritt an, um zu starten"
        case .riding:
            if engine.sensorless { return "Fahrt läuft ohne Trainer und Kadenz – Pause mit ⌃⌥P oder beiden Click-Tasten" }
            if engine.speedFromCadence { return "Fahrt läuft ohne Trainer – Tempo aus Trittfrequenz und Gang" }
            return "Fahrt läuft"
        case .paused: return engine.manualPause ? "Pausiert" : "Automatisch pausiert"
        case .finished: return "Beendet"
        }
    }

    private func shortcut(_ keys: String, _ text: String) -> some View {
        GridRow {
            Text(keys)
                .font(.system(size: 14, weight: .semibold, design: .monospaced))
                .foregroundStyle(Theme.accentSoft)
            Text(text)
                .font(Theme.text(14, .regular))
        }
    }
}

/// Change distance or duration during a free ride.
struct GoalEditor: View {
    @Environment(AppModel.self) private var model
    let engine: RideEngine

    @State private var kind: GoalKind = .distance
    @State private var distanceKm: Double = 30
    @State private var durationMin: Double = 60

    var body: some View {
        Card("Ziel ändern") {
            HStack(spacing: 8) {
                ForEach(GoalKind.allCases) { k in
                    ChoiceChip(title: k.title, selected: kind == k) { kind = k }
                }
                Spacer()
                Text("Aktuell: \(engine.config.goal.label)")
                    .font(Theme.text(13, .medium))
                    .foregroundStyle(Theme.secondary)
            }
            HStack(spacing: 14) {
                if kind == .distance {
                    Slider(value: $distanceKm, in: minimumKm...300, step: 1)
                    Text("\(Int(distanceKm)) km")
                        .font(Theme.number(24, .bold))
                        .frame(width: 90, alignment: .trailing)
                } else {
                    Slider(value: $durationMin, in: minimumMin...360, step: 5)
                    Text(Fmt.clock(durationMin * 60, hours: true))
                        .font(Theme.number(24, .bold))
                        .frame(width: 90, alignment: .trailing)
                }
                Button("Übernehmen") {
                    model.setGoal(kind == .distance ? .distance(meters: distanceKm * 1000) : .duration(seconds: durationMin * 60))
                }
                .controlSize(.large)
            }
            Text(kind == .distance
                 ? "Längere Strecken werden einfach weitergeneriert, das bisherige Profil bleibt."
                 : "Bei einer Dauer zeigt die Leiste die nächsten Kilometer als mitlaufendes Profil.")
                .font(Theme.text(12, .regular))
                .foregroundStyle(Theme.secondary)
        }
        .onAppear(perform: syncFromEngine)
    }

    private var minimumKm: Double { Swift.max(1, ((engine.distance + 500) / 1000).rounded(.up)) }
    private var minimumMin: Double { Swift.max(5, ((engine.movingTime + 60) / 60).rounded(.up)) }

    private func syncFromEngine() {
        switch engine.config.goal {
        case let .distance(meters):
            kind = .distance
            distanceKm = Swift.max(minimumKm, (meters / 1000).rounded())
            durationMin = Swift.max(minimumMin, 60)
        case let .duration(seconds):
            kind = .duration
            durationMin = Swift.max(minimumMin, (seconds / 60).rounded())
            distanceKm = Swift.max(minimumKm, 30)
        case .workout:
            break
        }
    }
}

// MARK: - After the ride

struct SummaryView: View {
    @Environment(AppModel.self) private var model
    let ride: FinishedRide

    var body: some View {
        let s = ride.summary
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Geschafft!")
                        .font(Theme.text(30, .bold))
                    Text(ride.name)
                        .font(Theme.text(16, .medium))
                        .foregroundStyle(Theme.secondary)
                }

                if let outcome = model.ftpOutcome {
                    FTPResultCard(outcome: outcome)
                }

                Card("intervals.icu") {
                    uploadRow
                }

                if let entry = model.history.first(where: { $0.id == ride.filename }) {
                    RideDetailContent(entry: entry, zones: model.intervals.zones, fallbackFTP: model.intervals.effectiveFTP)
                } else {
                    Grid(horizontalSpacing: 14, verticalSpacing: 14) {
                        GridRow {
                            stat("ZEIT", Fmt.clock(s.movingTime, hours: true), nil)
                            stat("DISTANZ", Fmt.km(s.distance), "km")
                            stat("Ø GESCHWINDIGKEIT", Fmt.decimal(s.avgSpeed * 3.6, 1), "km/h")
                            stat("HÖHENMETER", "\(Int(s.ascent.rounded()))", "m")
                        }
                        GridRow {
                            stat("Ø LEISTUNG", "\(s.avgPower)", "W")
                            stat("NP", "\(s.normalizedPower)", "W")
                            stat("MAX", "\(s.maxPower)", "W")
                            stat("ARBEIT", "\(Int(s.kilojoules.rounded()))", "kJ")
                        }
                    }
                }

                HStack(spacing: 12) {
                    Button("FIT exportieren…") { saveFIT() }
                    Spacer()
                    Text("Die Fahrt ist in der Historie gespeichert.")
                        .font(Theme.text(13, .regular))
                        .foregroundStyle(Theme.secondary)
                    Button("Fertig") { model.discardRide() }
                        .keyboardShortcut(.defaultAction)
                }
                .controlSize(.large)
            }
            .padding(28)
        }
    }

    @ViewBuilder
    private var uploadRow: some View {
        switch ride.uploadState {
        case .idle:
            HStack {
                Text("Gesichert, noch nicht hochgeladen.")
                    .foregroundStyle(Theme.secondary)
                Spacer()
                Button("Hochladen") { model.upload(ride) }
                    .disabled(!model.intervals.isConfigured)
            }
        case .waitingForKey:
            HStack(spacing: 10) {
                Image(systemName: "externaldrive.badge.checkmark").foregroundStyle(Theme.ok)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Fahrt gesichert. Sie wird automatisch hochgeladen, sobald du einen API-Key einträgst.")
                    Text("Du kannst die App auch schließen, die Fahrt geht nicht verloren.")
                        .font(Theme.text(12, .regular))
                        .foregroundStyle(Theme.secondary)
                }
                Spacer()
                SettingsLink { Text("API-Key eintragen") }
            }
        case .uploading:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Wird hochgeladen…")
            }
        case let .uploaded(id):
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.ok)
                Text("Hochgeladen")
                if !id.isEmpty, let url = URL(string: "https://intervals.icu/activities/\(id)") {
                    Link("In intervals.icu öffnen", destination: url)
                }
            }
        case let .queued(message):
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    Image(systemName: "clock.arrow.circlepath").foregroundStyle(Theme.warn)
                    Text("Upload fehlgeschlagen. Die Fahrt ist gesichert und wird später automatisch erneut hochgeladen.")
                    Spacer()
                    Button("Nochmal") { model.upload(ride) }
                }
                Text(message).font(Theme.text(12, .regular)).foregroundStyle(Theme.secondary)
            }
        case let .failed(message):
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.bad)
                Text(message)
                Spacer()
                Button("Nochmal") { model.upload(ride) }
            }
        }
    }

    private func stat(_ label: String, _ value: String, _ unit: String?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            MetricLabel(text: label, size: 11)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value).font(Theme.number(34, .bold))
                if let unit { Text(unit).font(Theme.text(13)).foregroundStyle(Theme.label) }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.tile))
    }

    private func saveFIT() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = ride.filename
        panel.allowedContentTypes = [.init(filenameExtension: "fit") ?? .data]
        if panel.runModal() == .OK, let url = panel.url {
            try? ride.fit.write(to: url)
        }
    }
}
