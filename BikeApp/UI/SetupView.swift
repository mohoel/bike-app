import AppKit
import SwiftUI

/// Choose free ride or workout, course, goal and display, then start.
struct SetupView: View {
    @Environment(AppModel.self) private var model

    private enum Kind: String, CaseIterable, Identifiable {
        case freeRide, workout, ftpTest
        var id: String { rawValue }
        var title: String {
            switch self {
            case .freeRide: return "Freie Fahrt"
            case .workout: return "Workout"
            case .ftpTest: return "FTP-Test"
            }
        }
    }

    @State private var kind: Kind = .freeRide
    @State private var seed: UInt64 = UInt64.random(in: 1...999_999)
    @State private var selectedWorkoutId: String?
    @State private var showDevices = false
    /// Workout open in the editor (new or existing).
    @State private var editing: CustomWorkout?

    var body: some View {
        @Bindable var settings = model.settings
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                devicesCard

                Card("Training") {
                    HStack(spacing: 8) {
                        ForEach(Kind.allCases) { k in
                            ChoiceChip(title: k.title, selected: kind == k) { kind = k }
                        }
                    }
                    switch kind {
                    case .freeRide:
                        courseSection
                        goalSection
                    case .workout:
                        workoutSection
                    case .ftpTest:
                        ftpTestSection
                    }
                }

                Card("Anzeige") {
                    HStack(spacing: 8) {
                        ForEach(DisplayMode.allCases) { mode in
                            ChoiceChip(title: mode.title, selected: settings.defaultDisplay == mode) { settings.defaultDisplay = mode }
                        }
                        Spacer()
                        Text(settings.defaultDisplay == .bar ? "Schwebende Leiste über deiner Serie" : "Großes Dashboard im Vollbild")
                            .font(Theme.text(13, .regular))
                            .foregroundStyle(Theme.secondary)
                    }
                }

                startButton
            }
            .padding(28)
        }
        .sheet(isPresented: $showDevices) {
            DevicesView()
                .environment(model)
        }
        .sheet(item: $editing) { workout in
            WorkoutEditorView(draft: workout) { saved in
                selectedWorkoutId = saved.asWorkout.id
            }
            .environment(model)
        }
    }

    // MARK: Header and devices

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Bike App")
                    .font(Theme.text(30, .bold))
                Text("Kickr Core 2 · Zwift Cog · Zwift Click")
                    .font(Theme.text(14, .medium))
                    .foregroundStyle(Theme.secondary)
            }
            Spacer()
            SettingsLink {
                Label("Einstellungen", systemImage: "gearshape")
            }
            .controlSize(.large)
        }
    }

    private var devicesCard: some View {
        Card("Geräte") {
            HStack(spacing: 10) {
                ForEach(model.ble.visibleRoles) { role in
                    deviceChip(role)
                }
            }
            HStack {
                if model.ble.isDemo {
                    Label("Demo-Modus aktiv – Trainer, Puls und Kadenz werden simuliert.", systemImage: "wand.and.stars")
                        .font(Theme.text(13, .medium))
                        .foregroundStyle(Theme.accentSoft)
                } else if model.ble.bluetoothState == .unauthorized {
                    Label("Bluetooth-Zugriff erlauben: Systemeinstellungen › Datenschutz & Sicherheit › Bluetooth.", systemImage: "exclamationmark.triangle")
                        .font(Theme.text(13, .medium))
                        .foregroundStyle(Theme.warn)
                }
                Spacer()
                Button("Geräte verwalten…") { showDevices = true }
            }
        }
    }

    private func deviceChip(_ role: DeviceRole) -> some View {
        let status = model.ble.status[role] ?? DeviceStatus()
        let color: Color = status.state.isUsable ? Theme.ok : (status.state == .notAssigned ? Color.white.opacity(0.3) : Theme.warn)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: role.symbol)
                    .foregroundStyle(color)
                Text(role.title)
                    .font(Theme.text(14, .semibold))
            }
            Text(status.name ?? status.state.label)
                .font(Theme.text(12, .regular))
                .foregroundStyle(Theme.secondary)
                .lineLimit(1)
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(status.detail ?? status.state.label)
                    .font(Theme.text(11, .medium))
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
                if let battery = status.battery {
                    Text("\(battery) %")
                        .font(Theme.text(11, .medium))
                        .foregroundStyle(Theme.secondary)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.chip))
        .accessibilityElement(children: .combine)
    }

    // MARK: Free ride

    private var courseSection: some View {
        @Bindable var settings = model.settings
        let range = settings.gradeRange
        let preview = ElevationProfile(range: range, seed: seed)
        let length = settings.goalKind == .distance ? settings.goalDistanceKm * 1000 : 20_000
        return VStack(alignment: .leading, spacing: 12) {
            MetricLabel(text: "STRECKE", size: 11)
            HStack(spacing: 8) {
                ForEach(CoursePreset.allCases) { preset in
                    ChoiceChip(title: preset.title, selected: settings.coursePreset == preset, tint: presetColor(preset)) {
                        settings.coursePreset = preset
                    }
                }
            }
            if settings.coursePreset == .custom {
                VStack(alignment: .leading, spacing: 6) {
                    sliderRow("Minimum", value: $settings.customMinGrade, range: -15...0)
                    sliderRow("Maximum", value: $settings.customMaxGrade, range: 0...20)
                }
            }
            ProfileBarsView(columns: preview.columns(from: 0, to: length, count: 150), marker: nil, spacing: 2, minHeight: 4, highlightCurrent: false)
                .frame(height: 84)
                .padding(.top, 4)
            HStack {
                Text("\(Fmt.signedGrade(range.min)) bis +\(Fmt.decimal(range.max, 0)) % · ↑ \(Int(preview.ascent(upTo: length).rounded())) hm auf \(Fmt.km(length)) km")
                    .font(Theme.text(13, .medium))
                    .foregroundStyle(Theme.secondary)
                Spacer()
                Button {
                    seed = UInt64.random(in: 1...999_999)
                } label: {
                    Label("Neu würfeln", systemImage: "dice")
                }
            }
        }
    }

    private func presetColor(_ preset: CoursePreset) -> Color {
        Theme.gradeColor(preset.range?.max ?? 6)
    }

    private func sliderRow(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        HStack {
            Text(title).frame(width: 80, alignment: .leading)
            Slider(value: value, in: range, step: 0.5)
            Text("\(Fmt.signedGrade(value.wrappedValue)) %")
                .font(Theme.number(16, .bold))
                .frame(width: 60, alignment: .trailing)
        }
    }

    private var goalSection: some View {
        @Bindable var settings = model.settings
        return VStack(alignment: .leading, spacing: 12) {
            MetricLabel(text: "ZIEL", size: 11)
            HStack(spacing: 8) {
                ForEach(GoalKind.allCases) { goal in
                    ChoiceChip(title: goal.title, selected: settings.goalKind == goal) { settings.goalKind = goal }
                }
            }
            if settings.goalKind == .distance {
                HStack {
                    Slider(value: $settings.goalDistanceKm, in: 5...200, step: 5)
                    Text("\(Int(settings.goalDistanceKm)) km")
                        .font(Theme.number(24, .bold))
                        .frame(width: 90, alignment: .trailing)
                }
            } else {
                HStack {
                    Slider(value: $settings.goalDurationMin, in: 10...300, step: 5)
                    Text(Fmt.clock(settings.goalDurationMin * 60, hours: true))
                        .font(Theme.number(24, .bold))
                        .frame(width: 90, alignment: .trailing)
                }
            }
        }
    }

    // MARK: Workout

    private var customWorkouts: [Workout] {
        model.customWorkouts.workouts.map(\.asWorkout)
    }

    private var intervalsWorkouts: [Workout] {
        model.intervals.isConfigured ? model.intervals.upcoming + model.intervals.library : []
    }

    private var workouts: [Workout] {
        customWorkouts + intervalsWorkouts
    }

    private var selectedWorkout: Workout? {
        workouts.first { $0.id == selectedWorkoutId } ?? workouts.first
    }

    @ViewBuilder
    private var workoutSection: some View {
        @Bindable var settings = model.settings
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                MetricLabel(text: "EIGENE WORKOUTS", size: 11)
                Spacer()
                Button {
                    editing = CustomWorkout(name: "Neues Workout", blocks: CustomWorkout.templates[0].blocks.map { $0.copy() })
                } label: {
                    Label("Neues Workout", systemImage: "plus")
                }
            }
            if customWorkouts.isEmpty {
                Text("Noch keine eigenen Workouts. Erstelle eins mit „Neues Workout“ oder kopiere ein intervals.icu-Workout über das Menü (…) in seiner Zeile.")
                    .font(Theme.text(13, .regular))
                    .foregroundStyle(Theme.secondary)
            } else {
                VStack(spacing: 8) {
                    ForEach(customWorkouts) { workout in
                        workoutRow(workout)
                    }
                }
            }

            intervalsWorkoutList
                .padding(.top, 6)

            MetricLabel(text: "MODUS", size: 11)
                .padding(.top, 6)
            HStack(spacing: 8) {
                ForEach(WorkoutMode.allCases) { mode in
                    ChoiceChip(title: mode.title, selected: settings.workoutMode == mode) { settings.workoutMode = mode }
                }
            }
            Text(settings.workoutMode.detail)
                .font(Theme.text(13, .regular))
                .foregroundStyle(Theme.secondary)
            if settings.workoutMode == .simTargets {
                courseSection
            }
            if model.intervals.athlete?.ftp == nil || !settings.useIntervalsFTP {
                Text("FTP für die Ziele: \(model.intervals.effectiveFTP) W (aus den Einstellungen)")
                    .font(Theme.text(12, .medium))
                    .foregroundStyle(Theme.secondary)
            }
        }
    }

    @ViewBuilder
    private var intervalsWorkoutList: some View {
        if !model.intervals.isConfigured {
            VStack(alignment: .leading, spacing: 6) {
                MetricLabel(text: "INTERVALS.ICU", size: 11)
                Text("Verbinde intervals.icu, um geplante Workouts zu laden. Den API-Key findest du dort unter Einstellungen › Developer Settings.")
                    .font(Theme.text(13, .regular))
                    .foregroundStyle(Theme.secondary)
                SettingsLink { Text("Einstellungen öffnen") }
            }
        } else {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    MetricLabel(text: "INTERVALS.ICU · GEPLANT (7 TAGE) UND BIBLIOTHEK", size: 11)
                    Spacer()
                    switch model.intervals.state {
                    case .loading: ProgressView().controlSize(.small)
                    case let .failed(message): Text(message).font(Theme.text(12, .regular)).foregroundStyle(Theme.bad).lineLimit(2)
                    default: EmptyView()
                    }
                    Button {
                        Task { await model.intervals.refreshAll() }
                    } label: {
                        Label("Aktualisieren", systemImage: "arrow.clockwise")
                    }
                }
                if intervalsWorkouts.isEmpty {
                    Text("Keine Rad-Workouts gefunden. Lege in intervals.icu ein Workout vom Typ Ride oder Virtual Ride in den Kalender oder die Bibliothek.")
                        .font(Theme.text(13, .regular))
                        .foregroundStyle(Theme.secondary)
                } else {
                    VStack(spacing: 8) {
                        ForEach(intervalsWorkouts) { workout in
                            workoutRow(workout)
                        }
                    }
                }
            }
        }
    }

    private func workoutRow(_ workout: Workout) -> some View {
        let selected = selectedWorkout?.id == workout.id
        return HStack(spacing: 10) {
            Button {
                selectedWorkoutId = workout.id
            } label: {
                HStack(spacing: 14) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(workout.name)
                            .font(Theme.text(14, .semibold))
                            .lineLimit(1)
                        Text(workoutSubtitle(workout))
                            .font(Theme.text(12, .regular))
                            .foregroundStyle(Theme.secondary)
                    }
                    .frame(width: 260, alignment: .leading)
                    WorkoutChartView(steps: workout.steps, elapsed: 0, zones: model.intervals.zones, gap: 1, minHeight: 3)
                        .frame(height: 34)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            workoutMenu(workout)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(selected ? Theme.accent.opacity(0.18) : Theme.chip))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(selected ? Theme.accent : .clear, lineWidth: 1.5))
    }

    private func workoutMenu(_ workout: Workout) -> some View {
        let custom = model.customWorkouts.workout(id: workout.id)
        return Menu {
            if let custom {
                Button("Bearbeiten…") { editing = custom }
                Button("Duplizieren") {
                    let copy = model.customWorkouts.duplicate(custom)
                    selectedWorkoutId = copy.asWorkout.id
                }
                Button("Als intervals.icu-Text kopieren") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(custom.intervalsText, forType: .string)
                }
                Divider()
                Button("Löschen", role: .destructive) {
                    model.customWorkouts.delete(custom.id)
                    if selectedWorkoutId == workout.id { selectedWorkoutId = nil }
                }
            } else {
                Button("Als eigenes Workout bearbeiten…") {
                    var copy = CustomWorkout.from(workout)
                    copy.name = workout.name
                    editing = copy
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 15))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Aktionen für \(workout.name)")
    }

    private func workoutSubtitle(_ workout: Workout) -> String {
        var parts: [String] = []
        if workout.id.hasPrefix(CustomWorkout.idPrefix) {
            parts.append("Eigenes Workout")
        } else if let date = workout.date {
            parts.append(date.formatted(.dateTime.weekday(.wide).day().month(.abbreviated).locale(Locale(identifier: "de_DE"))))
        } else {
            parts.append("Bibliothek")
        }
        parts.append(Fmt.clock(workout.duration, hours: true))
        return parts.joined(separator: " · ")
    }

    // MARK: FTP test

    private var ftpTestSection: some View {
        @Bindable var settings = model.settings
        let plan = model.makeTestPlan(settings.ftpTestKind)
        let source = plan.baseIsKnown ? "aus intervals.icu" : "aus den Einstellungen"
        let duration = plan.kind == .ramp ? "ca. 20–30 min" : "ca. \(Int((plan.workout.duration / 60).rounded())) min"
        return VStack(alignment: .leading, spacing: 12) {
            MetricLabel(text: "TEST", size: 11)
            HStack(spacing: 8) {
                ForEach(FTPTestKind.allCases) { k in
                    ChoiceChip(title: k.title, selected: settings.ftpTestKind == k) { settings.ftpTestKind = k }
                }
            }
            Text(plan.kind.detail)
                .font(Theme.text(13, .regular))
                .foregroundStyle(Theme.secondary)
            WorkoutChartView(steps: previewSteps(plan), elapsed: 0, zones: model.intervals.zones, gap: 1, minHeight: 3,
                             top: Swift.max(1.2, (previewSteps(plan).compactMap(\.startFraction).max() ?? 1) * 1.05))
                .frame(height: 70)
            HStack {
                Text("Ausgangswert für die Ziele: \(plan.baseFTP) W (\(source))")
                Spacer()
                Text(duration)
            }
            .font(Theme.text(12, .medium))
            .foregroundStyle(Theme.secondary)
            if plan.kind == .ramp {
                Label("Wenn du nicht mehr kannst: aufhören zu treten, beide Click-Tasten drücken oder „Test beenden“ in der Leiste.", systemImage: "flag.checkered")
                    .font(Theme.text(13, .medium))
            } else {
                Label("In den 20 Minuten hält der Kickr keine Watt: Schalte mit dem Click und fahre so gleichmäßig wie möglich.", systemImage: "plusminus.circle")
                    .font(Theme.text(13, .medium))
            }
            Toggle("Ergebnis automatisch als neue FTP übernehmen (App und intervals.icu)", isOn: $settings.autoTransferFTP)
            if !model.intervals.isConfigured {
                Text("Ohne API-Key wird das Ergebnis zu intervals.icu übertragen, sobald du ihn einträgst.")
                    .font(Theme.text(12, .regular))
                    .foregroundStyle(Theme.secondary)
            }
        }
    }

    /// The ramp ends when the rider is done; the preview shows it up to about 140 % FTP.
    private func previewSteps(_ plan: FTPTestPlan) -> [WorkoutStep] {
        guard plan.kind == .ramp else { return plan.workout.steps }
        let shown = plan.workout.steps.filter { ($0.startFraction ?? 0) <= 1.4 || $0.label == "Ausfahren" }
        return shown
    }

    // MARK: Start

    private var canStart: Bool {
        kind != .workout || selectedWorkout != nil
    }

    /// What works differently when devices are missing. Starting is always possible.
    private var missingDevicesHint: String? {
        let ble = model.ble
        func usable(_ role: DeviceRole) -> Bool { ble.status[role]?.state.isUsable == true }
        let clickOK = usable(.click) || usable(.clickLeft)
        var parts: [String] = []
        if !usable(.trainer) {
            parts.append(usable(.cadence) ? "Ohne Trainer: Tempo aus Kadenz und Gang, keine Watt" : "Ohne Trainer und Kadenz: nur Zeit und Puls, Pause von Hand")
        }
        if !clickOK { parts.append("ohne Click: schalten mit ⌃⌥↑/↓ oder in der Leiste") }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " · ") + ". Du kannst trotzdem starten."
    }

    private var startButton: some View {
        HStack(spacing: 14) {
            if let hint = missingDevicesHint {
                Label(hint, systemImage: "info.circle")
                    .font(Theme.text(13, .medium))
                    .foregroundStyle(Theme.warn)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button(action: start) {
                Text("Los geht's")
                    .font(Theme.text(18, .bold))
                    .foregroundStyle(Theme.onAccent)
                    .padding(.horizontal, 34)
                    .padding(.vertical, 14)
                    .background(Capsule().fill(canStart ? Theme.accent : Theme.accent.opacity(0.35)))
            }
            .buttonStyle(.plain)
            .disabled(!canStart)
            .keyboardShortcut(.defaultAction)
        }
    }

    private func start() {
        let settings = model.settings
        let range = settings.gradeRange
        let courseTitle = "\(settings.coursePreset.title) · \(Fmt.signedGrade(range.min)) … +\(Fmt.decimal(range.max, 0)) %"
        if kind == .ftpTest {
            let plan = model.makeTestPlan(settings.ftpTestKind)
            model.startRide(SessionConfig(
                name: plan.workout.name,
                courseTitle: plan.kind.title,
                gradeRange: GradeRange(min: 0, max: 0),
                seed: seed,
                goal: .workout,
                workout: plan.workout,
                workoutMode: .ergGears,
                presetTitle: "FTP-Test",
                test: plan
            ))
        } else if kind == .workout, let workout = selectedWorkout {
            model.startRide(SessionConfig(
                name: workout.name,
                courseTitle: courseTitle,
                gradeRange: range,
                seed: seed,
                goal: .workout,
                workout: workout,
                workoutMode: settings.workoutMode
            ))
        } else {
            let goal: SessionGoal = settings.goalKind == .distance
                ? .distance(meters: settings.goalDistanceKm * 1000)
                : .duration(seconds: settings.goalDurationMin * 60)
            let goalText = settings.goalKind == .distance ? "\(Int(settings.goalDistanceKm)) km" : "\(Int(settings.goalDurationMin)) min"
            model.startRide(SessionConfig(
                name: "Bike App – \(settings.coursePreset.title) \(goalText)",
                courseTitle: courseTitle,
                gradeRange: range,
                seed: seed,
                goal: goal,
                workout: nil,
                workoutMode: settings.workoutMode,
                presetTitle: settings.coursePreset.title
            ))
        }
        seed = UInt64.random(in: 1...999_999)
    }
}
