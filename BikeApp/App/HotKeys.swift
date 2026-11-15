import Carbon.HIToolbox
import Foundation

/// System-wide keyboard shortcuts via Carbon hot keys (no accessibility permission needed).
@MainActor
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    private var handlers: [UInt32: () -> Void] = [:]
    private var refs: [EventHotKeyRef] = []
    private var nextId: UInt32 = 1
    private var installed = false

    /// ⌃⌥ is used for all shortcuts of the app.
    nonisolated static let modifiers = UInt32(controlKey | optionKey)

    func register(keyCode: Int, modifiers: UInt32 = HotKeyCenter.modifiers, handler: @escaping () -> Void) {
        installIfNeeded()
        let id = nextId
        nextId += 1
        var ref: EventHotKeyRef?
        let hotKeyId = EventHotKeyID(signature: OSType(0x424B_4150), id: id) // "BKAP"
        let status = RegisterEventHotKey(UInt32(keyCode), modifiers, hotKeyId, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return }
        refs.append(ref)
        handlers[id] = handler
    }

    fileprivate func fire(_ id: UInt32) {
        handlers[id]?()
    }

    private func installIfNeeded() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hotKeyId = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyId)
            guard status == noErr else { return status }
            let id = hotKeyId.id
            DispatchQueue.main.async {
                MainActor.assumeIsolated { HotKeyCenter.shared.fire(id) }
            }
            return noErr
        }, 1, &spec, nil, nil)
    }
}
