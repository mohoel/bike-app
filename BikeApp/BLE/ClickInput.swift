import Foundation

/// Combines the buttons of all connected Zwift controllers into shift and pause actions.
///
/// The original Click is one device with + and −. The Click v2 is two devices (right = +,
/// left = −), so "both buttons together" spans two connections and has to be judged here.
@MainActor
final class ClickInputRouter {
    /// Pressed buttons per connected controller.
    private var pressed: [UUID: Set<ClickButtonKey>] = [:]
    private var interpreter = ClickButtonInterpreter()
    private var repeatTask: Task<Void, Never>?
    private let settings: AppSettings

    var onShift: ((ShiftDirection) -> Void)?
    var onBothButtons: (() -> Void)?
    /// While set, the next pressed button is reported here instead of shifting.
    var onLearn: ((ClickButtonKey) -> Void)?

    init(settings: AppSettings) {
        self.settings = settings
    }

    /// Learned assignments: button -> direction.
    var mapping: [ClickButtonKey: ShiftDirection] {
        var result: [ClickButtonKey: ShiftDirection] = [:]
        for (key, value) in settings.clickButtonMap {
            guard let button = ClickButtonKey(storageKey: key) else { continue }
            result[button] = value == "up" ? .up : .down
        }
        return result
    }

    /// Direction of one button: learned mapping first, then the pod's natural side.
    func direction(for key: ClickButtonKey) -> ShiftDirection? {
        switch key {
        case .v1Plus: return .up
        case .v1Minus: return .down
        default: break
        }
        let mapping = self.mapping
        if let learned = mapping[key] { return learned }
        // Once a pod has learned buttons, its other buttons stay unassigned.
        if mapping.keys.contains(where: { $0.pod == key.pod }) { return nil }
        switch key.pod {
        case .right: return .up
        case .left: return .down
        case .v1: return nil
        }
    }

    func update(source: UUID, pressed keys: Set<ClickButtonKey>) {
        let previous = pressed[source] ?? []
        pressed[source] = keys
        if let onLearn, let new = keys.subtracting(previous).first {
            onLearn(new)
            return
        }
        guard onLearn == nil else { return }
        evaluate()
    }

    func remove(source: UUID) {
        guard pressed.removeValue(forKey: source) != nil else { return }
        evaluate()
    }

    private func evaluate() {
        var buttons = ZwiftClickProtocol.Buttons()
        for key in pressed.values.flatMap({ $0 }) {
            switch direction(for: key) {
            case .up: buttons.plus = true
            case .down: buttons.minus = true
            case nil: break
            }
        }
        for action in interpreter.process(buttons) {
            switch action {
            case let .shift(direction): onShift?(direction)
            case let .startRepeat(direction): startRepeat(direction)
            case .stopRepeat: repeatTask?.cancel()
            case .bothPressed: onBothButtons?()
            }
        }
    }

    /// Holding a button repeats the shift after a short delay.
    private func startRepeat(_ direction: ShiftDirection) {
        repeatTask?.cancel()
        repeatTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            while !Task.isCancelled {
                guard let self, self.interpreter.isHeld(direction) else { return }
                self.onShift?(direction)
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
    }
}
