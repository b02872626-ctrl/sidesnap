import AppKit

/// Sidesnap lives in the menu bar only (no Dock icon). This file starts the
/// app, builds the menu, and wires the other pieces together.
@main
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    private var statusItem: NSStatusItem!
    private let menu = NSMenu()

    func applicationDidFinishLaunching(_ notification: Notification) {
        Migration.run()          // once: bring over the shelf and settings from Snapshelf
        Prefs.registerDefaults()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            MenuIcon.shared.attach(to: button)
        }
        menu.delegate = self
        statusItem.menu = menu
        rebuildMenu()
        installEditMenu()
        AppHub.shared.start()
        _ = MainActor.assumeIsolated { Updater.shared }   // starts the daily update check
    }

    /// A menu-bar app has no menus of its own, and macOS sends ⌘A, ⌘C, ⌘V,
    /// ⌘X and ⌘Z to text boxes through the Edit menu. This invisible one makes
    /// them work in the editor's text boxes and the search field.
    private func installEditMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Sidesnap", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)
        NSApp.mainMenu = main
    }

    // Rebuilt each time it opens, so the "Allow Screen Access" row is current.
    func menuNeedsUpdate(_ menu: NSMenu) { rebuildMenu() }

    private func rebuildMenu() {
        menu.removeAllItems()
        if !Permission.hasAccess {
            menu.addItem(item("Allow Screen Access…", #selector(allowAccess)))
            menu.addItem(.separator())
        }
        menu.addItem(item("Capture Area", #selector(captureArea), combo: Prefs.combo(.area)))
        menu.addItem(item("Capture Window", #selector(captureWindow), combo: Prefs.combo(.window)))
        menu.addItem(item("Capture Full Screen", #selector(captureFull), combo: Prefs.combo(.full)))
        menu.addItem(item("Copy Text from Area", #selector(captureText), combo: Prefs.combo(.text)))
        menu.addItem(.separator())
        let pause = item("Pause Shelf History", #selector(togglePause))
        pause.state = Prefs.pauseHistory ? .on : .off
        menu.addItem(pause)
        menu.addItem(.separator())
        let update = MainActor.assumeIsolated { Updater.shared.availableVersion }
        menu.addItem(item(update.map { "Install Update \($0)…" } ?? "Check for Updates…", #selector(checkUpdates)))
        menu.addItem(item("Settings…", #selector(showSettings), key: ",", mods: [.command]))
        menu.addItem(item("Welcome…", #selector(showWelcome)))
        menu.addItem(item("About Sidesnap", #selector(about)))
        menu.addItem(item("Quit Sidesnap", #selector(quit), key: "q", mods: [.command]))
    }

    private func item(_ title: String, _ action: Selector, key: String = "",
                      mods: NSEvent.ModifierFlags = [], combo: KeyCombo? = nil) -> NSMenuItem {
        let k = combo.map { $0.char.lowercased() } ?? key
        let i = NSMenuItem(title: title, action: action, keyEquivalent: k.count == 1 ? k : "")
        i.keyEquivalentModifierMask = combo?.mods ?? mods
        i.target = self
        return i
    }

    @objc private func captureArea() { AppHub.shared.capture.start(.area) }
    @objc private func captureWindow() { AppHub.shared.capture.start(.window) }
    @objc private func captureFull() { AppHub.shared.capture.start(.full) }
    @objc private func captureText() { AppHub.shared.capture.start(.text) }
    @objc private func allowAccess() { Permission.openSettings() }
    @objc private func showWelcome() { AppHub.shared.showFirstRun() }
    @objc private func showSettings() { AppHub.shared.showSettings() }
    @objc private func togglePause() {
        UserDefaults.standard.set(!Prefs.pauseHistory, forKey: Prefs.Key.pauseHistory)
    }
    @objc private func checkUpdates() { MainActor.assumeIsolated { Updater.shared.checkNow() } }
    @objc private func about() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(nil)
    }
    @objc private func quit() { NSApp.terminate(nil) }
}

/// Holds the long-lived parts of the app.
final class AppHub {
    static let shared = AppHub()

    let store = ShelfStore()
    lazy var capture = CaptureController(store: store) { [weak self] item, from in
        self?.didCapture(item, from: from)
    }
    lazy var card = CornerCardController(store: store)
    lazy var edge = EdgeTabController(store: store)
    lazy var editor = EditorController(store: store)
    private let hotKeys = HotKeys()
    private let onboarding = OnboardingController()
    private let settings = SettingsController()

    func start() {
        reloadHotKeys()
        // Clear screenshots past "Keep screenshots for" while the app keeps running, not only at launch.
        Timer.scheduledTimer(withTimeInterval: 3 * 3600, repeats: true) { [weak self] _ in self?.store.removeOld() }

        card.onClose = { [weak self] in self?.edge.cardClosed() }
        card.onEdit = { [weak self] in self?.editor.open($0) }
        edge.onEdit = { [weak self] in self?.editor.open($0) }
        edge.start()
        MenuIcon.shared.state = Permission.hasAccess ? .ready : .needsAccess

        if !UserDefaults.standard.bool(forKey: "didOnboard") { showFirstRun() }
    }

    /// Registers the capture shortcuts from Settings.
    func reloadHotKeys() {
        hotKeys.unregisterAll()
        hotKeys.register(id: 1, combo: Prefs.combo(.area)) { [weak self] in self?.capture.start(.area) }
        hotKeys.register(id: 2, combo: Prefs.combo(.window)) { [weak self] in self?.capture.start(.window) }
        hotKeys.register(id: 3, combo: Prefs.combo(.full)) { [weak self] in self?.capture.start(.full) }
        hotKeys.register(id: 4, combo: Prefs.combo(.text)) { [weak self] in self?.capture.start(.text) }
    }

    /// While a new shortcut is being typed in Settings.
    func pauseHotKeys() { hotKeys.unregisterAll() }

    func showSettings() { settings.show() }

    func showFirstRun() {
        onboarding.show()
    }

    private func didCapture(_ item: ShelfItem, from rect: NSRect) {
        MenuIcon.shared.flashCaptured()
        edge.cardOpened()
        card.show(item, from: rect)
    }
}
