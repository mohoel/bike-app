import SwiftUI

struct MenuBarLabel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.isRiding, let engine = model.engine {
            Text("\(engine.power3s) W")
                .monospacedDigit()
        } else {
            Image(systemName: "bicycle")
        }
    }
}

struct MenuBarContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if model.isRiding, let engine = model.engine {
            Text("\(engine.config.name)")
            Button(engine.phase == .paused ? "Weiter (⌃⌥P)" : "Pause (⌃⌥P)") { model.togglePause() }
            if engine.canChangeGoal {
                Text("Ziel: \(engine.config.goal.label)")
                Button(engine.config.goal.kind == .distance ? "Ziel +5 km" : "Ziel +5 min") { model.adjustGoal(by: 1) }
                Button(engine.config.goal.kind == .distance ? "Ziel −5 km" : "Ziel −5 min") { model.adjustGoal(by: -1) }
            }
            Button("Fahrt beenden") { model.stopRide() }
            Divider()
            if model.spotify.isRunning {
                Button(model.spotify.isPlaying ? "Musik pausieren" : "Musik abspielen") { model.spotify.playPause() }
                Button("Nächster Titel") { model.spotify.next() }
                Divider()
            }
            Button(model.displayMode == .bar ? "Vollbild (⌃⌥F)" : "Leiste (⌃⌥F)") { model.toggleDisplayMode() }
            Button(model.overlayVisible ? "Leiste ausblenden (⌃⌥B)" : "Leiste einblenden (⌃⌥B)") { model.toggleOverlay() }
            Toggle("Leiste durchklickbar (⌃⌥K)", isOn: Binding(get: { model.clickThrough }, set: { _ in model.toggleClickThrough() }))
            Divider()
        }
        Button("Bike App öffnen") {
            NSApp.activate()
            openWindow(id: "main")
        }
        SettingsLink { Text("Einstellungen…") }
        Divider()
        Button("Beenden") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
