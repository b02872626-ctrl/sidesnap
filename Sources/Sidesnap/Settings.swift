import AppKit
import SwiftUI
import ServiceManagement

final class SettingsController {
    private var window: NSWindow?

    func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 620),
                             styleMask: [.titled, .closable, .miniaturizable],
                             backing: .buffered, defer: false)
            w.title = "Sidesnap Settings"
            w.isReleasedWhenClosed = false
            w.appearance = NSAppearance(named: .darkAqua)
            w.contentView = NSHostingView(rootView: SettingsView())
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {
    enum Pane: String, CaseIterable {
        case general = "General", shortcuts = "Shortcuts", privacy = "Privacy"
        var symbol: String {
            switch self {
            case .general: return "gearshape"
            case .shortcuts: return "keyboard"
            case .privacy: return "hand.raised"
            }
        }
    }
    @State private var pane: Pane = .general

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                ForEach(Pane.allCases, id: \.self) { p in
                    Button { pane = p } label: {
                        VStack(spacing: 3) {
                            Image(systemName: p.symbol).font(.system(size: 17))
                            Text(p.rawValue).font(.system(size: 11))
                        }
                        .frame(width: 80, height: 46)
                        .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(pane == p ? 0.1 : 0)))
                        .foregroundStyle(pane == p ? .primary : .secondary)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(pane == p ? .isSelected : [])
                }
            }
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(Color(white: 0.16))
            .overlay(Rectangle().fill(Color.white.opacity(0.08)).frame(height: 0.5), alignment: .bottom)

            Group {
                switch pane {
                case .general: GeneralPane()
                case .shortcuts: ShortcutsPane()
                case .privacy: PrivacyPane()
                }
            }
            .formStyle(.grouped)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 640, height: 620)
    }
}

// MARK: - General

struct GeneralPane: View {
    @ObservedObject private var updater = Updater.shared
    @AppStorage(Prefs.Key.copyOnCapture) private var copy = true
    @AppStorage(Prefs.Key.saveOnCapture) private var saveFile = false
    @AppStorage(Prefs.Key.playSound) private var sound = true
    @AppStorage(Prefs.Key.sliverAfter) private var sliverAfter = 5
    @AppStorage(Prefs.Key.hideAfter) private var hideAfter = 300
    @AppStorage(Prefs.Key.keepDays) private var keepDays = 30
    @State private var openAtLogin = SMAppService.mainApp.status == .enabled
    @State private var folder = Prefs.saveFolder

    var body: some View {
        Form {
            Section {
                Toggle("Check for updates automatically", isOn: $updater.checksAutomatically)
                Toggle("Open at login", isOn: $openAtLogin)
                    .onChange(of: openAtLogin) { _, on in
                        if on { try? SMAppService.mainApp.register() } else { try? SMAppService.mainApp.unregister() }
                    }
            }
            Section("After a capture") {
                Toggle("Copy to clipboard", isOn: $copy)
                Toggle("Also save a file", isOn: $saveFile)
                LabeledContent("Save files to") {
                    HStack {
                        Text(folder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                            .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        Button("Choose…") { chooseFolder() }
                    }
                }
                Toggle("Play a sound", isOn: $sound)
            }
            Section {
                Picker("Shrink to a sliver", selection: $sliverAfter) {
                    Text("After 3 seconds").tag(3)
                    Text("After 5 seconds").tag(5)
                    Text("After 10 seconds").tag(10)
                    Text("After 30 seconds").tag(30)
                    Text("Never").tag(0)
                }
                Picker("Hide completely", selection: $hideAfter) {
                    Text("After 1 minute").tag(60)
                    Text("After 5 minutes").tag(300)
                    Text("After 15 minutes").tag(900)
                    Text("Never").tag(0)
                }
            } header: {
                Text("Edge tab")
            } footer: {
                Text("It also shrinks when you click somewhere else. Point at the right edge to bring it back.")
                    .foregroundStyle(.secondary)
            }
            Section {
                Picker("Keep screenshots for", selection: $keepDays) {
                    Text("7 days").tag(7)
                    Text("30 days").tag(30)
                    Text("90 days").tag(90)
                    Text("Forever").tag(0)
                }
                .onChange(of: keepDays) { _, _ in AppHub.shared.store.removeOld() }
                LabeledContent("Clear the shelf") {
                    Button("Clear Shelf…") { clearShelf() }
                }
            } header: {
                Text("Shelf")
            } footer: {
                Text("Pinned screenshots are always kept.").foregroundStyle(.secondary)
            }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = folder
        panel.prompt = "Use This Folder"
        if panel.runModal() == .OK, let url = panel.url {
            Prefs.saveFolder = url
            folder = url
        }
    }

    private func clearShelf() {
        let store = AppHub.shared.store
        let count = store.items.filter { !$0.isPinned }.count
        let alert = NSAlert()
        alert.messageText = "Clear the shelf?"
        alert.informativeText = count == 0
            ? "There's nothing to clear. Pinned screenshots always stay."
            : "This removes \(count) screenshot\(count == 1 ? "" : "s") from this Mac. Pinned ones stay. This can't be undone."
        if count > 0 {
            alert.addButton(withTitle: "Clear")
            alert.addButton(withTitle: "Cancel")
        } else {
            alert.addButton(withTitle: "OK")
        }
        if alert.runModal() == .alertFirstButtonReturn, count > 0 { store.clear(keepPinned: true) }
    }
}

// MARK: - Shortcuts

struct ShortcutsPane: View {
    @State private var combos = Prefs.Action.allCases.map { Prefs.combo($0) }
    @State private var recording: Prefs.Action?
    @State private var errors: [Prefs.Action: String] = [:]
    @State private var monitor: Any?

    private let editorKeys: [(String, String)] = [
        ("Select", "V"), ("Arrow", "A"), ("Text", "T"), ("Speech bubble", "U"), ("Box", "R"),
        ("Blur", "B"), ("Highlight", "H"), ("Pen", "P"), ("Numbered step", "N"), ("Crop", "C"),
        ("Copy", "⌘C"), ("Copy the text in it", "⇧⌘C"), ("Save", "⌘S"), ("Pin", "⌘P"), ("Undo", "⌘Z"),
        ("Remove the selected mark", "Delete"), ("Copy the color under the pointer", "Tab"),
    ]

    var body: some View {
        Form {
            Section("Capture") {
                ForEach(Array(Prefs.Action.allCases.enumerated()), id: \.element) { i, action in
                    VStack(alignment: .leading, spacing: 4) {
                        LabeledContent(action.title) {
                            Button { startRecording(action) } label: {
                                Text(recording == action ? "Type a shortcut…" : combos[i].display)
                                    .frame(minWidth: 120)
                                    .foregroundStyle(recording == action ? .secondary : .primary)
                            }
                            .buttonStyle(.bordered)
                            .tint(recording == action ? .accentColor : nil)
                            .help("Click, then press the new shortcut. Esc cancels.")
                        }
                        if let e = errors[action] {
                            Text(e).font(.system(size: 11.5)).foregroundStyle(Color(red: 1, green: 0.7, blue: 0.25))
                        }
                    }
                }
                HStack {
                    Spacer()
                    Button("Restore Defaults") {
                        for a in Prefs.Action.allCases { Prefs.setCombo(nil, for: a) }
                        combos = Prefs.Action.allCases.map { Prefs.combo($0) }
                        errors = [:]
                        AppHub.shared.reloadHotKeys()
                    }
                }
            }
            Section("In the editor") {
                ForEach(editorKeys, id: \.0) { name, key in
                    LabeledContent(name) {
                        Text(key).font(.system(size: 12)).monospaced()
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.08)))
                    }
                }
            }
        }
        .onDisappear { stopRecording() }
    }

    private func startRecording(_ action: Prefs.Action) {
        stopRecording()
        recording = action
        errors[action] = nil
        AppHub.shared.pauseHotKeys()   // so pressing the old shortcut doesn't start a capture
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            if e.keyCode == 53 { stopRecording(); return nil }    // Esc
            let char = e.characters(byApplyingModifiers: []) ?? e.charactersIgnoringModifiers ?? ""
            let name = e.keyCode == 49 ? " " : (e.keyCode == 48 ? "TAB" : char)
            let combo = KeyCombo(keyCode: UInt32(e.keyCode), mods: e.modifierFlags, char: name)
            if let problem = combo.problem {
                errors[action] = problem
            } else if let other = Prefs.Action.allCases.first(where: { $0 != action && Prefs.combo($0) == combo }) {
                errors[action] = "\(combo.display) is already used for \(other.title.lowercased())."
            } else {
                Prefs.setCombo(combo, for: action)
                combos = Prefs.Action.allCases.map { Prefs.combo($0) }
                errors[action] = nil
            }
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
        if recording != nil { AppHub.shared.reloadHotKeys() }
        recording = nil
    }
}

// MARK: - Privacy

struct PrivacyPane: View {
    @AppStorage(Prefs.Key.pauseHistory) private var paused = false
    @AppStorage(Prefs.Key.readText) private var readText = true
    @State private var allowed = Permission.hasAccess
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section {
                LabeledContent {
                    HStack(spacing: 10) {
                        Label(allowed ? "Allowed" : "Off", systemImage: allowed ? "checkmark" : "xmark")
                            .foregroundStyle(.secondary)
                        Button("Open System Settings") { Permission.openSettings() }
                    }
                } label: {
                    Text("Screen access")
                    Text("Needed to capture. Set by macOS, not by Sidesnap.")
                }
            }
            Section("Shelf history") {
                Toggle(isOn: $paused) {
                    Text("Pause shelf history")
                    Text("Captures go to the clipboard only. Nothing is kept.")
                }
            }
            Section {
                Toggle(isOn: $readText) {
                    Text("Read text in screenshots")
                    Text("Makes search work. Runs on this Mac only.")
                }
                .onChange(of: readText) { _, on in if on { AppHub.shared.store.readMissingText() } }
            } header: {
                Text("Text")
            } footer: {
                Text("Some apps, like video players, are blocked by macOS and come out black. That's expected.")
                    .foregroundStyle(.secondary)
            }
        }
        .onReceive(timer) { _ in allowed = Permission.hasAccess }
    }
}
