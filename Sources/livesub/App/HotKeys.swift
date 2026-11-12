import AppKit
import Carbon.HIToolbox

/// System-wide keyboard shortcuts (work while another app, such as the browser, is in front).
/// Uses Carbon hot keys, which need no Accessibility permission.
@MainActor
enum HotKeys {
    private static var handlers: [UInt32: () -> Void] = [:]
    private static var installed = false

    /// - Parameters:
    ///   - keyCode: virtual key code (kVK_ANSI_C, …).
    ///   - modifiers: Carbon modifier mask (controlKey | optionKey, …).
    static func register(id: UInt32, keyCode: Int, modifiers: Int, handler: @escaping () -> Void) {
        installHandlerIfNeeded()
        handlers[id] = handler
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x4C53_7562) /* 'LSub' */, id: id)
        let status = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hotKeyID, GetApplicationEventTarget(), 0, &ref)
        if status != noErr { print("warning: could not register shortcut \(id) (in use by another app?)") }
    }

    private static func installHandlerIfNeeded() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let id = hotKeyID.id
            // Hot key events are delivered on the main thread.
            MainActor.assumeIsolated { HotKeys.handlers[id]?() }
            return noErr
        }, 1, &spec, nil, nil)
    }
}
