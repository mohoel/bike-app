import AppKit
import Carbon.HIToolbox
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Unit tests run inside the app: they get empty, separate data and never touch the real key or rides.
    let model: AppModel = AppDelegate.isRunningTests ? AppModel.isolated(suite: "BikeAppTestHost") : AppModel()
    private var overlay: OverlayPanelController?
    private var fullscreen: FullscreenWindowController?
    private var keyMonitor: Any?

    static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !Self.isRunningTests else { return }
        overlay = OverlayPanelController(model: model)
        fullscreen = FullscreenWindowController(model: model)
        model.coordinator = self
        model.bootstrap()
        registerHotKeys()
        installKeyMonitor()
        // Development: `open BikeApp.app --args -BikeAppAutostartDemo YES` starts a simulated ride.
        if UserDefaults.standard.bool(forKey: "BikeAppAutostartDemo") {
            model.ble.startTemporaryDemo()
            model.startRide(SessionConfig(
                name: "Demo-Fahrt",
                courseTitle: "Hügelig · −5 … +7 %",
                gradeRange: GradeRange(min: -5, max: 7),
                seed: 502,
                goal: .distance(meters: 5000),
                workout: nil,
                workoutMode: .ergOffset
            ))
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        guard !Self.isRunningTests else { return }
        model.appDidBecomeActive()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { model.openMainWindow?() }
        return true
    }

    // MARK: Keyboard

    private func registerHotKeys() {
        let hk = HotKeyCenter.shared
        hk.register(keyCode: kVK_UpArrow) { [weak self] in self?.model.shift(.up) }
        hk.register(keyCode: kVK_DownArrow) { [weak self] in self?.model.shift(.down) }
        hk.register(keyCode: kVK_ANSI_P) { [weak self] in self?.model.togglePause() }
        hk.register(keyCode: kVK_ANSI_F) { [weak self] in
            guard let self, self.model.isRiding else { return }
            self.model.toggleDisplayMode()
        }
        hk.register(keyCode: kVK_ANSI_B) { [weak self] in self?.model.toggleOverlay() }
        hk.register(keyCode: kVK_ANSI_K) { [weak self] in self?.model.toggleClickThrough() }
    }

    /// Plain keys while the app itself is active (e.g. in the full screen view).
    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.model.isRiding else { return event }
            // Leave typing in text fields alone.
            if let responder = NSApp.keyWindow?.firstResponder, responder is NSTextView { return event }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard flags.subtracting([.function, .numericPad]).isEmpty else { return event }
            switch Int(event.keyCode) {
            case kVK_UpArrow, kVK_ANSI_Equal, kVK_ANSI_KeypadPlus:
                self.model.shift(.up)
                return nil
            case kVK_DownArrow, kVK_ANSI_Minus, kVK_ANSI_KeypadMinus:
                self.model.shift(.down)
                return nil
            case kVK_Space:
                self.model.togglePause()
                return nil
            default:
                return event
            }
        }
    }

    private func bringMainWindowToFront() {
        NSApp.activate()
        if let window = NSApp.windows.first(where: { $0.title == "Bike App" && !($0 is NSPanel) }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            model.openMainWindow?()
        }
    }
}

extension AppDelegate: RideUICoordinator {
    func rideDidStart() {
        displayModeChanged()
    }

    func rideDidFinish() {
        overlay?.hide()
        fullscreen?.close()
        bringMainWindowToFront()
    }

    func displayModeChanged() {
        guard model.isRiding else { return }
        switch model.displayMode {
        case .bar:
            fullscreen?.close()
            if model.overlayVisible { overlay?.show() }
        case .fullscreen:
            overlay?.hide()
            fullscreen?.show()
        }
    }

    func overlayStateChanged() {
        overlay?.setClickThrough(model.clickThrough)
        guard model.isRiding, model.displayMode == .bar else { return }
        if model.overlayVisible { overlay?.show() } else { overlay?.hide() }
    }
}
