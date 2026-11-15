import AppKit
import SwiftUI

/// Areas of the overlay where clicks go to buttons instead of moving the panel.
final class OverlayHitRegions {
    /// Rects in the hosting view, top-left origin (SwiftUI global coordinates).
    var interactive: [String: CGRect] = [:]

    func contains(_ point: CGPoint) -> Bool {
        interactive.values.contains { $0.contains(point) }
    }
}

/// Capsule button used in the overlay.
struct OverlayButtonStyle: ButtonStyle {
    let s: CGFloat
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.text(13 * s, .semibold))
            .labelStyle(.titleAndIcon)
            .foregroundStyle(prominent ? Theme.barBase : .white)
            .padding(.horizontal, 12 * s)
            .frame(height: 28 * s)
            .background(Capsule().fill(prominent ? Color.white.opacity(configuration.isPressed ? 0.75 : 1) : Color.white.opacity(configuration.isPressed ? 0.24 : 0.1)))
            .contentShape(Capsule())
    }
}

/// Round icon-only button used in the overlay.
struct OverlayIconButton: View {
    let symbol: String
    let label: String
    let s: CGFloat
    var size: CGFloat = 28
    var filled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12 * s * size / 28, weight: .bold))
                .foregroundStyle(filled ? Theme.barBase : .white)
                .frame(width: size * s, height: size * s)
                .background(Circle().fill(filled ? Color.white : Color.white.opacity(0.1)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .help(label)
    }
}

/// Third row of the bar: Spotify on the left, ride controls on the right.
struct OverlayControlRow: View {
    @Environment(AppModel.self) private var model
    let engine: RideEngine
    let s: CGFloat
    var regions: OverlayHitRegions?

    var body: some View {
        HStack(spacing: 10 * s) {
            MusicControls(spotify: model.spotify, s: s)
            Spacer(minLength: 10 * s)
            rideControls
        }
        // Keep the corner free for the resize grip.
        .padding(.trailing, 16 * s)
        .frame(height: 36 * s)
        .onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: .global)
        } action: { rect in
            regions?.interactive["controls"] = rect
        }
    }

    private var clickConnected: Bool {
        [DeviceRole.click, .clickLeft].contains { model.ble.status[$0]?.state.isUsable == true }
    }

    private var rideControls: some View {
        HStack(spacing: 8 * s) {
            if engine.canEndTestEffort {
                Button {
                    model.endTestEffort()
                } label: {
                    Label("Test beenden", systemImage: "flag.checkered")
                }
                .buttonStyle(OverlayButtonStyle(s: s, prominent: true))
                .help("Rampe beenden, wenn du nicht mehr kannst (auch: aufhören zu treten oder beide Click-Tasten)")
            } else {
                Button {
                    model.togglePause()
                } label: {
                    Label(engine.phase == .paused ? "Weiter" : "Pause", systemImage: engine.phase == .paused ? "play.fill" : "pause.fill")
                }
                .buttonStyle(OverlayButtonStyle(s: s, prominent: engine.phase == .paused))
                .help("Pause / weiter (beide Click-Tasten oder ⌃⌥P)")
            }

            if !clickConnected {
                // Without a Click the bar gets its own shift buttons.
                HStack(spacing: 6 * s) {
                    OverlayIconButton(symbol: "minus", label: engine.clickAdjustsErgOffset ? "5 W weniger" : "Leichter schalten", s: s, size: 24) { model.shift(.down) }
                    VStack(spacing: 0) {
                        Text(engine.clickAdjustsErgOffset ? "ERG" : "GANG")
                            .font(Theme.text(9 * s, .bold))
                            .tracking(0.7 * s)
                            .foregroundStyle(Theme.label)
                        Text(engine.clickAdjustsErgOffset ? (engine.ergOffset >= 0 ? "+\(engine.ergOffset)" : "−\(abs(engine.ergOffset))") : "\(engine.gearbox.gear)")
                            .font(Theme.number(15 * s, .bold))
                    }
                    .frame(minWidth: 40 * s)
                    OverlayIconButton(symbol: "plus", label: engine.clickAdjustsErgOffset ? "5 W mehr" : "Schwerer schalten", s: s, size: 24) { model.shift(.up) }
                }
                .padding(.horizontal, 3 * s)
                .frame(height: 30 * s)
                .background(Capsule().fill(Color.white.opacity(0.06)))
                .help("Kein Click verbunden: hier oder mit ⌃⌥↑/↓ schalten")
            }

            if engine.canChangeGoal {
                HStack(spacing: 6 * s) {
                    OverlayIconButton(symbol: "minus", label: "Ziel verkürzen", s: s, size: 24) { model.adjustGoal(by: -1) }
                    VStack(spacing: 0) {
                        Text("ZIEL")
                            .font(Theme.text(9 * s, .bold))
                            .tracking(0.7 * s)
                            .foregroundStyle(Theme.label)
                        Text(engine.config.goal.label)
                            .font(Theme.number(15 * s, .bold))
                    }
                    .frame(minWidth: 52 * s)
                    OverlayIconButton(symbol: "plus", label: "Ziel verlängern", s: s, size: 24) { model.adjustGoal(by: 1) }
                }
                .padding(.horizontal, 3 * s)
                .frame(height: 30 * s)
                .background(Capsule().fill(Color.white.opacity(0.06)))
            }

            OverlayIconButton(symbol: "arrow.up.left.and.arrow.down.right", label: "Vollbild", s: s) { model.toggleDisplayMode() }
        }
    }
}

/// Now playing and play controls for Spotify.
struct MusicControls: View {
    let spotify: SpotifyController
    let s: CGFloat

    var body: some View {
        if !spotify.isInstalled {
            EmptyView()
        } else if spotify.permissionDenied {
            Button {
                spotify.openPrivacySettings()
            } label: {
                Label("Spotify-Steuerung erlauben", systemImage: "lock.open")
            }
            .buttonStyle(OverlayButtonStyle(s: s))
            .help("Systemeinstellungen › Datenschutz & Sicherheit › Automation › Bike App › Spotify")
        } else if spotify.isRunning {
            HStack(spacing: 10 * s) {
                artwork
                VStack(alignment: .leading, spacing: 1 * s) {
                    Text(spotify.track?.name ?? "Spotify")
                        .font(Theme.text(13 * s, .semibold))
                        .lineLimit(1)
                    Text(spotify.track?.artist ?? (spotify.isPlaying ? "" : "Pausiert"))
                        .font(Theme.text(11 * s, .medium))
                        .foregroundStyle(Theme.label)
                        .lineLimit(1)
                }
                .frame(maxWidth: 280 * s, alignment: .leading)
                HStack(spacing: 4 * s) {
                    OverlayIconButton(symbol: "backward.fill", label: "Vorheriger Titel", s: s, size: 26) { spotify.previous() }
                    OverlayIconButton(symbol: spotify.isPlaying ? "pause.fill" : "play.fill", label: spotify.isPlaying ? "Musik pausieren" : "Musik abspielen", s: s, filled: true) { spotify.playPause() }
                    OverlayIconButton(symbol: "forward.fill", label: "Nächster Titel", s: s, size: 26) { spotify.next() }
                }
            }
            .padding(.leading, 4 * s)
            .padding(.trailing, 4 * s)
            .frame(height: 36 * s)
            .background(Capsule().fill(Color.white.opacity(0.06)))
        } else {
            Button {
                spotify.launchAndPlay()
            } label: {
                Label("Spotify starten", systemImage: "music.note")
            }
            .buttonStyle(OverlayButtonStyle(s: s))
        }
    }

    @ViewBuilder
    private var artwork: some View {
        if let image = spotify.artwork {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 28 * s, height: 28 * s)
                .clipShape(RoundedRectangle(cornerRadius: 6 * s, style: .continuous))
                .accessibilityHidden(true)
        } else {
            Image(systemName: "music.note")
                .font(.system(size: 13 * s, weight: .bold))
                .foregroundStyle(Theme.accent)
                .frame(width: 28 * s, height: 28 * s)
                .background(RoundedRectangle(cornerRadius: 6 * s, style: .continuous).fill(Theme.chip))
                .accessibilityHidden(true)
        }
    }
}
