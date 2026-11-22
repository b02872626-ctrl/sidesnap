import AppKit
import ScreenCaptureKit

/// .text: pick an area, copy the words (or a QR code's link) in it, keep nothing.
enum CaptureMode { case area, window, full, text }

/// A window on screen that can be captured, in AppKit (bottom-left) coordinates.
struct ScreenWindow {
    let id: CGWindowID
    let frame: NSRect
    let appName: String
}

/// Runs a capture: shows the area/window picker, grabs the pixels with
/// ScreenCaptureKit, saves to the shelf and hands the result on.
final class CaptureController {
    private let store: ShelfStore
    private let onCaptured: (ShelfItem, NSRect) -> Void
    private var overlays: [SelectionWindow] = []
    private var previousApp: NSRunningApplication?
    private var pickingMode: CaptureMode = .area

    init(store: ShelfStore, onCaptured: @escaping (ShelfItem, NSRect) -> Void) {
        self.store = store
        self.onCaptured = onCaptured
    }

    func start(_ mode: CaptureMode) {
        guard overlays.isEmpty else { return }
        guard Permission.hasAccess else { Permission.showMissingAlert(); return }
        switch mode {
        case .full:
            let screen = Self.screenUnderMouse()
            grabArea(screen.frame, on: screen, kind: "Screen", title: "Full screen")
        case .area, .window, .text:
            pickingMode = mode
            showPicker(mode)
        }
    }

    // MARK: Picker

    private func showPicker(_ mode: CaptureMode) {
        MenuIcon.shared.state = .capturing
        previousApp = NSWorkspace.shared.frontmostApplication
        let windows = Self.onScreenWindows()
        for screen in NSScreen.screens {
            let w = SelectionWindow(screen: screen, mode: mode, windows: windows) { [weak self] result in
                self?.finishPicking(result)
            }
            overlays.append(w)
        }
        NSApp.activate(ignoringOtherApps: true)
        for w in overlays { w.orderFrontRegardless() }
        let mouse = NSEvent.mouseLocation
        (overlays.first { $0.frame.contains(mouse) } ?? overlays.first)?.makeKey()
    }

    private func finishPicking(_ result: SelectionResult) {
        for w in overlays { w.orderOut(nil) }
        overlays.removeAll()
        previousApp?.activate()
        MenuIcon.shared.state = .ready
        switch result {
        case .cancelled:
            break
        case let .area(rect, screen) where pickingMode == .text:
            grabText(rect, on: screen)
        case let .area(rect, screen):
            let app = Self.onScreenWindows().first { $0.frame.contains(NSPoint(x: rect.midX, y: rect.midY)) }?.appName
            grabArea(rect, on: screen, kind: "Area", title: app ?? "Screenshot")
        case let .window(win):
            grabWindow(win)
        }
    }

    // MARK: Grabbing pixels

    /// Copies the text (or QR code) inside an area to the clipboard. Nothing goes on the shelf.
    private func grabText(_ rect: NSRect, on screen: NSScreen) {
        Task { @MainActor in
            do {
                let image = try await self.pixels(of: rect, on: screen)
                TextReader.read(image) { found in
                    switch found {
                    case let .qr(link):
                        Self.copyString(link)
                        NotificationCenter.default.post(name: OnboardingController.textCopied, object: nil)
                        TextHUD.show("Copied QR code", detail: link, near: rect)
                    case let .text(text):
                        Self.copyString(text)
                        NotificationCenter.default.post(name: OnboardingController.textCopied, object: nil)
                        let lines = text.split(separator: "\n").count
                        TextHUD.show(lines == 1 ? "Copied text" : "Copied \(lines) lines of text",
                                     detail: String(text.prefix(80)), near: rect)
                    case .nothing:
                        TextHUD.show("No text found", detail: "Try selecting a little more around it.", near: rect)
                    }
                }
            } catch {
                NSSound.beep()
            }
        }
    }

    static func copyString(_ s: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(s, forType: .string)
    }

    /// Grabs the pixels of an area of one display, leaving out Sidesnap's own windows.
    private func pixels(of rect: NSRect, on screen: NSScreen) async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == screen.displayID }) else {
            throw CocoaError(.featureUnsupported)
        }
        let me = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: me, exceptingWindows: [])
        let cfg = SCStreamConfiguration()
        let scale = screen.backingScaleFactor
        cfg.sourceRect = CGRect(x: rect.minX - screen.frame.minX, y: screen.frame.maxY - rect.maxY,
                                width: rect.width, height: rect.height)
        cfg.width = Int(rect.width * scale)
        cfg.height = Int(rect.height * scale)
        cfg.showsCursor = false
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
    }

    private func grabArea(_ rect: NSRect, on screen: NSScreen, kind: String, title: String) {
        Task { @MainActor in
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = content.displays.first(where: { $0.displayID == screen.displayID }) else { return }
                // Never capture Sidesnap's own card, tab or picker.
                let me = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
                let filter = SCContentFilter(display: display, excludingApplications: me, exceptingWindows: [])
                let cfg = SCStreamConfiguration()
                let scale = screen.backingScaleFactor
                cfg.sourceRect = CGRect(x: rect.minX - screen.frame.minX,
                                        y: screen.frame.maxY - rect.maxY,
                                        width: rect.width, height: rect.height)
                cfg.width = Int(rect.width * scale)
                cfg.height = Int(rect.height * scale)
                cfg.showsCursor = false
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
                self.deliver(image, kind: kind, title: title, from: rect)
            } catch {
                NSSound.beep()
            }
        }
    }

    private func grabWindow(_ win: ScreenWindow) {
        Task { @MainActor in
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let w = content.windows.first(where: { $0.windowID == win.id }) else { return }
                let filter = SCContentFilter(desktopIndependentWindow: w)
                let cfg = SCStreamConfiguration()
                let screen = NSScreen.screens.first { $0.frame.intersects(win.frame) } ?? NSScreen.main
                let scale = screen?.backingScaleFactor ?? 2
                cfg.width = Int(w.frame.width * scale)
                cfg.height = Int(w.frame.height * scale)
                cfg.showsCursor = false
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
                self.deliver(image, kind: "Window", title: win.appName, from: win.frame)
            } catch {
                NSSound.beep()
            }
        }
    }

    private func deliver(_ image: CGImage, kind: String, title: String, from rect: NSRect) {
        Prefs.playCaptureSound()
        if Prefs.pauseHistory {
            // Paused: clipboard only, nothing kept.
            let screen = NSScreen.screens.first { $0.frame.intersects(rect) } ?? NSScreen.main
            let scale = screen?.backingScaleFactor ?? 2
            ShelfStore.copyToClipboard(NSImage(cgImage: image, size: NSSize(width: CGFloat(image.width) / scale,
                                                                            height: CGFloat(image.height) / scale)))
            MenuIcon.shared.flashCaptured()
            return
        }
        guard let item = store.add(image, kind: kind, title: title) else { NSSound.beep(); return }
        if Prefs.copyOnCapture { store.copy(item) }
        if Prefs.saveOnCapture { store.saveToPictures(item) }
        onCaptured(item, rect)
    }

    // MARK: Helpers

    static func screenUnderMouse() -> NSScreen {
        let p = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(p) } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    /// Normal app windows on screen, front to back, excluding Sidesnap.
    static func onScreenWindows() -> [ScreenWindow] {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]] else { return [] }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let me = ProcessInfo.processInfo.processIdentifier
        return info.compactMap { d in
            guard (d[kCGWindowLayer as String] as? Int) == 0,
                  (d[kCGWindowOwnerPID as String] as? pid_t) != me,
                  let id = d[kCGWindowNumber as String] as? CGWindowID,
                  let b = d[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = b["X"], let y = b["Y"], let w = b["Width"], let h = b["Height"],
                  w > 40, h > 40 else { return nil }
            let name = d[kCGWindowOwnerName as String] as? String ?? "Window"
            return ScreenWindow(id: id, frame: NSRect(x: x, y: primaryHeight - y - h, width: w, height: h), appName: name)
        }
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
}

// MARK: - Picker window

enum SelectionResult {
    case cancelled
    case area(NSRect, NSScreen)
    case window(ScreenWindow)
}

/// A clear full-screen window over one display that draws the dimmed picker.
final class SelectionWindow: NSWindow {
    init(screen: NSScreen, mode: CaptureMode, windows: [ScreenWindow], done: @escaping (SelectionResult) -> Void) {
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        setFrame(screen.frame, display: false)
        contentView = SelectionView(screen: screen, mode: mode, windows: windows, done: done)
    }
    override var canBecomeKey: Bool { true }
}

final class SelectionView: NSView {
    private let screen: NSScreen
    private var mode: CaptureMode
    private let windows: [ScreenWindow]
    private let done: (SelectionResult) -> Void
    private var start: NSPoint?
    private var current: NSPoint?
    private var hovered: ScreenWindow?

    init(screen: NSScreen, mode: CaptureMode, windows: [ScreenWindow], done: @escaping (SelectionResult) -> Void) {
        self.screen = screen
        self.mode = mode
        self.windows = windows
        self.done = done
        super.init(frame: NSRect(origin: .zero, size: screen.frame.size))
        if mode == .window { updateHover(NSEvent.mouseLocation) }
    }
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func viewDidMoveToWindow() { window?.makeFirstResponder(self) }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect, .cursorUpdate],
                                       owner: self, userInfo: nil))
    }
    override func cursorUpdate(with event: NSEvent) {
        (mode != .window ? NSCursor.crosshair : NSCursor.pointingHand).set()
    }

    private var selection: NSRect? {
        guard let s = start, let c = current else { return nil }
        return NSRect(x: min(s.x, c.x), y: min(s.y, c.y), width: abs(s.x - c.x), height: abs(s.y - c.y))
    }

    // MARK: Events

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { done(.cancelled) } // Esc
        if event.keyCode == 49 && mode != .text {   // Space switches area ↔ window, like macOS
            mode = mode == .area ? .window : .area
            start = nil; current = nil; hovered = nil
            if mode == .window { updateHover(NSEvent.mouseLocation) }
            window?.invalidateCursorRects(for: self)
            (mode == .area ? NSCursor.crosshair : NSCursor.pointingHand).set()
            needsDisplay = true
        }
    }

    override func mouseMoved(with event: NSEvent) {
        if mode == .window { updateHover(NSEvent.mouseLocation) }
    }

    override func mouseDown(with event: NSEvent) {
        if mode == .window {
            if let w = hovered { done(.window(w)) }
            return
        }
        start = convert(event.locationInWindow, from: nil)
        current = start
    }

    override func mouseDragged(with event: NSEvent) {
        guard mode != .window else { return }
        current = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard mode != .window, let sel = selection else { return }
        if sel.width < 4 || sel.height < 4 { start = nil; current = nil; needsDisplay = true; return }
        let global = sel.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY)
        done(.area(global, screen))
    }

    private func updateHover(_ p: NSPoint) {
        let w = windows.first { $0.frame.contains(p) && screen.frame.intersects($0.frame) }
        if w?.id != hovered?.id { hovered = w; needsDisplay = true }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let dim = NSColor.black.withAlphaComponent(mode != .window ? 0.38 : 0.2)
        if mode != .window, let sel = selection {
            let path = NSBezierPath(rect: bounds)
            path.append(NSBezierPath(rect: sel))
            path.windingRule = .evenOdd
            dim.setFill(); path.fill()
            let border = NSBezierPath(rect: sel.insetBy(dx: 0.5, dy: 0.5))
            border.setLineDash([5, 4], count: 2, phase: 0)
            border.lineWidth = 1
            NSColor.white.setStroke(); border.stroke()
            drawLabel("\(Int(sel.width)) × \(Int(sel.height))", near: sel)
        } else {
            dim.setFill(); bounds.fill()
        }
        if mode == .window, let w = hovered {
            let local = w.frame.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
            let path = NSBezierPath(roundedRect: local, xRadius: 10, yRadius: 10)
            NSColor.controlAccentColor.withAlphaComponent(0.22).setFill(); path.fill()
            path.lineWidth = 3
            NSColor.controlAccentColor.setStroke(); path.stroke()
        }
        if screen.frame.contains(NSEvent.mouseLocation) {
            drawHint(mode == .text ? "Select the text or QR code to copy   ·   Esc to cancel"
                     : mode == .area ? "Drag to select an area   ·   Space for a window   ·   Esc to cancel"
                                   : "Click a window to capture it   ·   Space for an area   ·   Esc to cancel")
        }
    }

    private func drawLabel(_ text: String, near sel: NSRect) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white]
        let size = (text as NSString).size(withAttributes: attrs)
        var box = NSRect(x: sel.minX, y: sel.maxY + 6, width: size.width + 14, height: size.height + 6)
        if box.maxY > bounds.maxY { box.origin.y = sel.maxY - box.height - 6 }
        NSColor.black.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: box, xRadius: 5, yRadius: 5).fill()
        (text as NSString).draw(at: NSPoint(x: box.minX + 7, y: box.minY + 3), withAttributes: attrs)
    }

    private func drawHint(_ text: String) {
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.white]
        let size = (text as NSString).size(withAttributes: attrs)
        let box = NSRect(x: bounds.midX - size.width / 2 - 16, y: bounds.maxY - 90, width: size.width + 32, height: size.height + 16)
        NSColor(white: 0.17, alpha: 0.94).setFill()
        NSBezierPath(roundedRect: box, xRadius: 12, yRadius: 12).fill()
        (text as NSString).draw(at: NSPoint(x: box.minX + 16, y: box.minY + 8), withAttributes: attrs)
    }
}
