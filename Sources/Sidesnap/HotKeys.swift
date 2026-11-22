import AppKit
import Carbon.HIToolbox

/// Global capture shortcuts (default ⌥⇧1, ⌥⇧2, ⌥⇧3) through the classic
/// Carbon hot key API. Unlike watching every key press, this needs no
/// Accessibility permission. Shortcuts can be changed in Settings.
final class HotKeys {
    private var handlers: [UInt32: () -> Void] = [:]
    private var refs: [EventHotKeyRef] = []
    /// Shortcuts another app already owns.
    private(set) var failed: [UInt32: Bool] = [:]

    init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let me = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, user in
            guard let event, let user else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &id)
            let keys = Unmanaged<HotKeys>.fromOpaque(user).takeUnretainedValue()
            DispatchQueue.main.async { keys.handlers[id.id]?() }
            return noErr
        }, 1, &spec, me, nil)
    }

    func register(id: UInt32, combo: KeyCombo, _ handler: @escaping () -> Void) {
        handlers[id] = handler
        var ref: EventHotKeyRef?
        let hkID = EventHotKeyID(signature: OSType(0x534E_5348), id: id) // "SNSH"
        let status = RegisterEventHotKey(combo.keyCode, combo.carbonMods, hkID,
                                         GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref { refs.append(ref) } else {
            // Another app already owns this shortcut; macOS gives it to them, not us.
            NSLog("Sidesnap: shortcut %@ could not be registered (status %d)", combo.display, status)
        }
        failed[id] = status != noErr
    }

    /// Removes every shortcut (before re-registering, or while a new one is being typed).
    func unregisterAll() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs.removeAll()
        handlers.removeAll()
        failed.removeAll()
    }
}
