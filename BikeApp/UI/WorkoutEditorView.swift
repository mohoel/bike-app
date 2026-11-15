import AppKit
import SwiftUI

/// Builds or edits a workout: blocks with duration and % FTP, repeat groups, live preview.
struct WorkoutEditorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var draft: CustomWorkout
    /// Called with the saved workout.
    var onSave: (CustomWorkout) -> Void = { _ in }
    @State private var copied = false

    private var ftp: Int { model.intervals.effectiveFTP }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            preview
            ScrollView {
                VStack(spacing: 8) {
                    ForEach($draft.blocks) { $block in
                        blockView($block, in: $draft.blocks)
                    }
                    if draft.blocks.isEmpty {
                        Text("Noch keine Abschnitte. Füge unten den ersten hinzu.")
                            .font(Theme.text(13, .regular))
                            .foregroundStyle(Theme.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(20)
                    }
                }
                .padding(.vertical, 2)
            }
            addBar(into: $draft.blocks, nested: false)
            footer
        }
        .padding(24)
        .frame(width: 760, height: 720)
        .background(Theme.background)
        .environment(\.colorScheme, .dark)
    }

    // MARK: Header and preview

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Name des Workouts", text: $draft.name)
                    .textFieldStyle(.plain)
                    .font(Theme.text(22, .bold))
                Spacer()
                Menu {
                    ForEach(CustomWorkout.templates, id: \.name) { template in
                        Button(template.name) {
                            draft.blocks = template.blocks.map { $0.copy() }
                            if draft.name.isEmpty || draft.name == "Neues Workout" { draft.name = template.name }
                        }
                    }
                } label: {
                    Label("Vorlage", systemImage: "square.grid.2x2")
                }
                .fixedSize()
            }
            TextField("Notiz (optional)", text: $draft.notes)
                .textFieldStyle(.plain)
                .font(Theme.text(13, .regular))
                .foregroundStyle(Theme.secondary)
        }
    }

    private var preview: some View {
        let steps = draft.steps
        let top = Swift.max(1.2, (steps.compactMap { Swift.max($0.startFraction ?? 0, $0.endFraction ?? 0) }.max() ?? 1) * 1.05)
        return VStack(alignment: .leading, spacing: 8) {
            WorkoutChartView(steps: steps, elapsed: 0, zones: model.intervals.zones, gap: 1, minHeight: 3, top: top)
                .frame(height: 90)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.chip.opacity(0.5)))
            HStack(spacing: 18) {
                stat("DAUER", Fmt.clock(draft.duration, hours: true))
                stat("TSS ≈", "\(draft.stressScore)")
                stat("IF ≈", Fmt.decimal(draft.intensityFactor, 2))
                stat("ABSCHNITTE", "\(steps.count)")
                Spacer()
                Text("FTP \(ftp) W")
                    .font(Theme.text(12, .medium))
                    .foregroundStyle(Theme.secondary)
            }
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            MetricLabel(text: label, size: 10)
            Text(value).font(Theme.number(17, .bold))
        }
    }

    // MARK: Blocks

    @ViewBuilder
    private func blockView(_ block: Binding<WorkoutBlock>, in list: Binding<[WorkoutBlock]>) -> some View {
        if block.wrappedValue.kind == .repeats {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Image(systemName: "repeat")
                        .foregroundStyle(Theme.accentSoft)
                    Stepper(value: block.reps, in: 1...30) {
                        Text("\(block.wrappedValue.reps) ×")
                            .font(Theme.number(18, .bold))
                    }
                    .fixedSize()
                    Text("= \(Fmt.clock(block.wrappedValue.totalDuration, hours: true))")
                        .font(Theme.text(12, .medium))
                        .foregroundStyle(Theme.secondary)
                    Spacer()
                    rowActions(block.wrappedValue, in: list)
                }
                ForEach(block.children) { $child in
                    stepRow($child, in: block.children)
                }
                addBar(into: block.children, nested: true)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.accent.opacity(0.5), lineWidth: 1.2))
        } else {
            stepRow(block, in: list)
        }
    }

    private func stepRow(_ block: Binding<WorkoutBlock>, in list: Binding<[WorkoutBlock]>) -> some View {
        let b = block.wrappedValue
        return HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 3)
                .fill(b.kind == .free ? Color.white.opacity(0.3) : Theme.zoneColor(model.intervals.zones.index(watts: Double(b.startPercent) / 100 * Double(ftp), ftp: Double(ftp))))
                .frame(width: 6, height: 34)
            Picker("", selection: block.kind) {
                ForEach([WorkoutBlock.Kind.steady, .ramp, .free]) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .frame(width: 104)
            DurationField(seconds: block.duration)
            switch b.kind {
            case .steady:
                PercentField(percent: block.startPercent, ftp: ftp)
            case .ramp:
                PercentField(percent: block.startPercent, ftp: ftp)
                Image(systemName: "arrow.right").foregroundStyle(Theme.secondary)
                PercentField(percent: block.endPercent, ftp: ftp)
            case .free, .repeats:
                Text("ohne ERG, du schaltest selbst")
                    .font(Theme.text(12, .regular))
                    .foregroundStyle(Theme.secondary)
            }
            TextField("Bezeichnung", text: block.label)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 90)
            rowActions(b, in: list)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.chip))
    }

    private func rowActions(_ block: WorkoutBlock, in list: Binding<[WorkoutBlock]>) -> some View {
        let index = list.wrappedValue.firstIndex { $0.id == block.id }
        return Menu {
            Button("Nach oben") { move(block.id, by: -1, in: list) }
                .disabled(index == 0)
            Button("Nach unten") { move(block.id, by: 1, in: list) }
                .disabled(index == list.wrappedValue.count - 1)
            Button("Duplizieren") {
                if let i = index { list.wrappedValue.insert(block.copy(), at: i + 1) }
            }
            Divider()
            Button("Löschen", role: .destructive) {
                list.wrappedValue.removeAll { $0.id == block.id }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Aktionen")
    }

    private func move(_ id: UUID, by offset: Int, in list: Binding<[WorkoutBlock]>) {
        guard let i = list.wrappedValue.firstIndex(where: { $0.id == id }) else { return }
        let j = i + offset
        guard list.wrappedValue.indices.contains(j) else { return }
        list.wrappedValue.swapAt(i, j)
    }

    private func addBar(into list: Binding<[WorkoutBlock]>, nested: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "plus")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Theme.secondary)
                .help(nested ? "Abschnitt in die Gruppe einfügen" : "Abschnitt hinzufügen")
            if !nested {
                addButton("Aufwärmen", "flame") { list.wrappedValue.append(.ramp(10, 45, 70, "Aufwärmen")) }
            }
            addButton("Konstant", "minus") { list.wrappedValue.append(.steady(5, nested ? 105 : 75)) }
            addButton("Rampe", "chart.line.uptrend.xyaxis") { list.wrappedValue.append(.ramp(5, 60, 90)) }
            addButton("Erholung", "leaf") { list.wrappedValue.append(.steady(3, 55, "Erholung")) }
            addButton("Frei", "bicycle") { list.wrappedValue.append(.free(5)) }
            if !nested {
                addButton("Intervalle", "repeat") {
                    list.wrappedValue.append(.repeats(4, [.steady(4, 105, "Intervall"), .steady(3, 55, "Erholung")]))
                }
                addButton("Ausfahren", "wind") { list.wrappedValue.append(.ramp(8, 65, 45, "Ausfahren")) }
            }
            Spacer(minLength: 0)
        }
    }

    private func addButton(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(Theme.text(12, .semibold))
                .fixedSize()
        }
        .controlSize(.small)
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(draft.intervalsText, forType: .string)
                copied = true
            } label: {
                Label(copied ? "Kopiert" : "Als intervals.icu-Text kopieren", systemImage: copied ? "checkmark" : "doc.on.doc")
            }
            .help("Text für den Workout-Editor von intervals.icu, z. B. um das Workout dort in den Kalender zu legen")
            Spacer()
            Button("Abbrechen") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Speichern") {
                draft.name = draft.name.trimmingCharacters(in: .whitespaces)
                model.customWorkouts.save(draft)
                onSave(draft)
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!draft.isValid)
        }
        .onChange(of: draft) { copied = false }
    }
}

/// Duration as "m:ss" text with ±30 s stepper.
struct DurationField: View {
    @Binding var seconds: TimeInterval
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 2) {
            TextField("", text: $text)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 62)
                .focused($focused)
                .onSubmit(commit)
                .onChange(of: focused) { if !focused { commit() } }
            Stepper("", value: Binding(get: { seconds }, set: { seconds = Swift.max(15, $0); text = Self.format(seconds) }), in: 15...14_400, step: 30)
                .labelsHidden()
        }
        .onAppear { text = Self.format(seconds) }
        .onChange(of: seconds) { if !focused { text = Self.format(seconds) } }
        .help("Dauer als Minuten:Sekunden, z. B. 4:30, oder nur Minuten")
    }

    private func commit() {
        if let parsed = Self.parse(text) { seconds = parsed }
        text = Self.format(seconds)
    }

    static func format(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded())
        if s >= 3600 { return String(format: "%d:%02d:%02d", s / 3600, s % 3600 / 60, s % 60) }
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    /// "4:30" → 270, "10" → 600 (minutes), "1:02:00" → 3720.
    static func parse(_ text: String) -> TimeInterval? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":").map { Int($0) }
        guard !parts.isEmpty, parts.allSatisfy({ $0 != nil }) else { return nil }
        let v = parts.compactMap { $0 }
        let total: Int
        switch v.count {
        case 1: total = v[0] * 60
        case 2: total = v[0] * 60 + v[1]
        case 3: total = v[0] * 3600 + v[1] * 60 + v[2]
        default: return nil
        }
        return total > 0 ? TimeInterval(total) : nil
    }
}

/// Percent of FTP with ±5 % stepper and the resulting watts.
struct PercentField: View {
    @Binding var percent: Int
    let ftp: Int

    var body: some View {
        HStack(spacing: 2) {
            TextField("", value: Binding(get: { percent }, set: { percent = Swift.min(300, Swift.max(10, $0)) }), format: .number)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 46)
            Text("%")
            Stepper("", value: $percent, in: 10...300, step: 5)
                .labelsHidden()
            Text("\(Int((Double(percent) / 100 * Double(ftp)).rounded())) W")
                .font(Theme.text(11, .medium))
                .foregroundStyle(Theme.secondary)
                .frame(width: 42, alignment: .leading)
        }
    }
}
