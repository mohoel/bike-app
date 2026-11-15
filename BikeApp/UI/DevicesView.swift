import SwiftUI

/// Pair devices to roles; scanning runs while the sheet is open.
struct DevicesView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Geräte")
                    .font(Theme.text(22, .bold))
                Spacer()
                if model.ble.isScanning {
                    ProgressView().controlSize(.small)
                    Text("Suche läuft…").foregroundStyle(Theme.secondary)
                } else {
                    Button("Erneut suchen") { model.ble.startScan(duration: 60) }
                }
            }
            Text("Wecke die Geräte auf: Kurbel drehen, Pulsgurt anlegen, Click-Taste drücken. Der Click v2 besteht aus zwei Geräten (rechts +, links −), beide werden einzeln gekoppelt. Kein Gerät ist Pflicht: Was fehlt, ersetzt die App so gut es geht.")
                .font(Theme.text(13, .regular))
                .foregroundStyle(Theme.secondary)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(model.ble.visibleRoles) { role in
                        roleSection(role)
                    }
                    clickMappingCard
                }
            }

            HStack {
                Toggle("Demo-Modus (ohne Hardware)", isOn: Binding(get: { model.ble.isDemo }, set: { model.ble.setDemoMode($0) }))
                Spacer()
                Button("Fertig") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 580, height: 640)
        .background(Theme.background)
        .environment(\.colorScheme, .dark)
        .onAppear { model.ble.startScan(duration: 60) }
        .onDisappear {
            model.ble.stopScan()
            model.ble.stopLearningButtons()
        }
    }

    /// Click v2: which buttons shift up and down.
    @ViewBuilder
    private var clickMappingCard: some View {
        let ble = model.ble
        if ble.assignedId(for: .click) != nil || ble.assignedId(for: .clickLeft) != nil {
            Card("Click-Tasten") {
                if let direction = ble.learningDirection {
                    Label(direction == .up ? "Drücke jetzt die Taste für SCHWERER." : "Drücke jetzt die Taste für LEICHTER.",
                          systemImage: direction == .up ? "plus.circle.fill" : "minus.circle.fill")
                        .font(Theme.text(15, .semibold))
                        .foregroundStyle(Theme.accentSoft)
                } else {
                    Text(model.settings.clickButtonMap.isEmpty
                         ? "Standard: Click v1 wie beschriftet. Beim Click v2 schaltet die rechte Hälfte schwerer, die linke leichter. Hast du nur eine Hälfte, ordne zwei ihrer Tasten zu."
                         : "Eigene Zuordnung aktiv (\(model.settings.clickButtonMap.count) Tasten).")
                        .font(Theme.text(13, .regular))
                        .foregroundStyle(Theme.secondary)
                }
                if let summary = ble.learnedSummary {
                    Text(summary)
                        .font(Theme.text(12, .medium))
                        .foregroundStyle(Theme.secondary)
                }
                HStack {
                    if ble.learningDirection == nil {
                        Button("Tasten zuordnen…") { ble.startLearningButtons() }
                        if !model.settings.clickButtonMap.isEmpty {
                            Button("Standard") { ble.resetButtonMapping() }
                        }
                    } else {
                        Button("Abbrechen") { ble.stopLearningButtons() }
                    }
                    Spacer()
                }
            }
        }
    }

    private func roleSection(_ role: DeviceRole) -> some View {
        let status = model.ble.status[role] ?? DeviceStatus()
        let candidates = model.ble.discovered.filter { $0.roles.contains(role) }
        return Card(role.title) {
            HStack {
                Image(systemName: role.symbol)
                VStack(alignment: .leading, spacing: 2) {
                    Text(status.name ?? "Kein Gerät")
                        .font(Theme.text(14, .semibold))
                    Text(status.detail ?? status.state.label)
                        .font(Theme.text(12, .regular))
                        .foregroundStyle(Theme.secondary)
                }
                Spacer()
                if model.ble.assignedId(for: role) != nil {
                    Button("Entfernen") { model.ble.unassign(role) }
                }
            }
            ForEach(candidates.filter { $0.id != model.ble.assignedId(for: role) }) { device in
                HStack {
                    Text(device.name)
                    Text("\(device.rssi) dBm")
                        .font(Theme.text(12, .regular))
                        .foregroundStyle(Theme.secondary)
                    Spacer()
                    Button("Verbinden") { model.ble.assign(device, to: role) }
                }
            }
        }
    }
}
