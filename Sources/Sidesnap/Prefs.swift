import AppKit
import SwiftUI
import Carbon.HIToolbox

/// Every setting, stored in UserDefaults. Views read the same keys with @AppStorage.
enum Prefs {
    static let changed = Notification.Name("SidesnapPrefsChanged")
    private static var d: UserDefaults { .standard }

    enum Key {
        static let copyOnCapture = "copyOnCapture"
        static let saveOnCapture = "saveOnCapture"
        static let saveFolder = "saveFolder"
        static let playSound = "playSound"
        static let sliverAfter = "sliverAfter"   // seconds, 0 = never
        static let hideAfter = "hideAfter"       // seconds, 0 = never
        static let keepDays = "keepDays"         // 0 = forever
        static let readText = "readText"
        static let pauseHistory = "pauseHistory"
    }

    static func registerDefaults() {
        // Carry over the first-run choice from 0.1/0.2.
        if let old = d.string(forKey: "afterCapture"), d.object(forKey: Key.copyOnCapture) == nil {
            d.set(old != "shelf", forKey: Key.copyOnCapture)
            d.set(old == "save", forKey: Key.saveOnCapture)
        }
        d.register(defaults: [
            Key.copyOnCapture: true, Key.saveOnCapture: false, Key.playSound: true,
            Key.sliverAfter: 5, Key.hideAfter: 300, Key.keepDays: 30,
            Key.readText: true, Key.pauseHistory: false,
        ])
    }

    static var copyOnCapture: Bool { d.bool(forKey: Key.copyOnCapture) }
    static var saveOnCapture: Bool { d.bool(forKey: Key.saveOnCapture) }
    static var playSound: Bool { d.bool(forKey: Key.playSound) }
    static var sliverAfter: Int { d.integer(forKey: Key.sliverAfter) }
    static var hideAfter: Int { d.integer(forKey: Key.hideAfter) }
    static var keepDays: Int { d.integer(forKey: Key.keepDays) }
    static var readText: Bool { d.bool(forKey: Key.readText) }
    static var pauseHistory: Bool { d.bool(forKey: Key.pauseHistory) }

    static var defaultSaveFolder: URL {
        FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Sidesnap", isDirectory: true)
    }
    static var saveFolder: URL {
        get { d.string(forKey: Key.saveFolder).map { URL(fileURLWithPath: $0, isDirectory: true) } ?? defaultSaveFolder }
        set { d.set(newValue.path, forKey: Key.saveFolder) }
    }

    /// The camera-shutter sound macOS uses for its own screenshots, if present.
    static func playCaptureSound() {
        guard playSound else { return }
        let path = "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Screen Capture.aif"
        (NSSound(contentsOfFile: path, byReference: true) ?? NSSound(named: "Pop"))?.play()
    }

    // MARK: Shortcuts

    enum Action: String, CaseIterable {
        case area, window, full, text
        var title: String {
            switch self {
            case .area: return "Capture area"
            case .window: return "Capture window"
            case .full: return "Capture full screen"
            case .text: return "Copy text or QR from an area"
            }
        }
        var defaultCombo: KeyCombo {
            let mods: NSEvent.ModifierFlags = [.option, .shift]
            switch self {
            // ⌥⇧S: select an area. ⌥S: the whole screen. Same keys the owner used in
            // Shottr, so no app command (Save As, strikethrough) is taken. 2026-11-20.
            case .area: return KeyCombo(keyCode: UInt32(kVK_ANSI_S), mods: [.option, .shift], char: "S")
            case .window: return KeyCombo(keyCode: UInt32(kVK_ANSI_2), mods: mods, char: "2")
            case .full: return KeyCombo(keyCode: UInt32(kVK_ANSI_S), mods: [.option], char: "S")
            case .text: return KeyCombo(keyCode: UInt32(kVK_ANSI_T), mods: [.option, .shift], char: "T")
            }
        }
    }

    static func combo(_ a: Action) -> KeyCombo {
        d.string(forKey: "hotkey.\(a.rawValue)").flatMap(KeyCombo.init(stored:)) ?? a.defaultCombo
    }
    static func setCombo(_ c: KeyCombo?, for a: Action) {
        if let c { d.set(c.stored, forKey: "hotkey.\(a.rawValue)") } else { d.removeObject(forKey: "hotkey.\(a.rawValue)") }
        NotificationCenter.default.post(name: changed, object: nil)
    }
}

/// Shared motion: critically damped springs (no overshoot) unless something
/// carries momentum, and gentler cross-fades when Reduce Motion is on.
enum Motion {
    static var reduce: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    static let settle = Animation.spring(response: 0.32, dampingFraction: 1)
    static let spread = Animation.spring(response: 0.42, dampingFraction: 1)
}

/// A keyboard shortcut like ⌥⇧1.
struct KeyCombo: Equatable {
    let keyCode: UInt32
    let mods: NSEvent.ModifierFlags
    let char: String

    init(keyCode: UInt32, mods: NSEvent.ModifierFlags, char: String) {
        self.keyCode = keyCode
        self.mods = mods.intersection([.command, .option, .control, .shift])
        self.char = char.uppercased()
    }

    init?(stored: String) {
        let parts = stored.split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count == 3, let k = UInt32(parts[0]), let m = UInt(parts[1]) else { return nil }
        self.init(keyCode: k, mods: NSEvent.ModifierFlags(rawValue: m), char: String(parts[2]))
    }

    var stored: String { "\(keyCode)|\(mods.rawValue)|\(char)" }

    var display: String {
        var s = ""
        if mods.contains(.control) { s += "⌃" }
        if mods.contains(.option) { s += "⌥" }
        if mods.contains(.shift) { s += "⇧" }
        if mods.contains(.command) { s += "⌘" }
        return s + char
    }

    var carbonMods: UInt32 {
        var m = 0
        if mods.contains(.command) { m |= cmdKey }
        if mods.contains(.option) { m |= optionKey }
        if mods.contains(.shift) { m |= shiftKey }
        if mods.contains(.control) { m |= controlKey }
        return UInt32(m)
    }

    /// Why this combo can't be used, or nil if it's fine.
    var problem: String? {
        if !mods.contains(.command) && !mods.contains(.control) && !mods.contains(.option) {
            return "Add ⌘, ⌥ or ⌃ so it doesn't fire while you type."
        }
        let taken: Set<String> = ["⇧⌘3", "⇧⌘4", "⇧⌘5", "⇧⌘6", "⌘ ", "⌘Q", "⌘W", "⌘C", "⌘V", "⌘X", "⌘Z", "⌘A", "⌘S", "⌘TAB"]
        if taken.contains(display) { return "\(display) is used by macOS. Pick another." }
        return nil
    }
}
