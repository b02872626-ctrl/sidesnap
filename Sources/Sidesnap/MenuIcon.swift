import AppKit

/// The menu bar icon and its states: ready, capturing, just captured
/// (a check for one second), and needs screen access.
final class MenuIcon {
    static let shared = MenuIcon()

    enum State { case ready, capturing, captured, needsAccess }

    private weak var button: NSStatusBarButton?
    private var flashTimer: Timer?

    var state: State = .ready { didSet { apply() } }

    func attach(to button: NSStatusBarButton) {
        self.button = button
        apply()
    }

    func flashCaptured() {
        state = .captured
        flashTimer?.invalidate()
        flashTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { [weak self] _ in
            self?.state = Permission.hasAccess ? .ready : .needsAccess
        }
    }

    private func apply() {
        let name: String
        switch state {
        case .ready: name = "rectangle.on.rectangle"
        case .capturing: name = "rectangle.fill.on.rectangle.fill"
        case .captured: name = "checkmark.rectangle"
        case .needsAccess: name = "rectangle.on.rectangle.slash"
        }
        let img = NSImage(systemSymbolName: name, accessibilityDescription: "Sidesnap")
            ?? NSImage(systemSymbolName: "rectangle.on.rectangle", accessibilityDescription: "Sidesnap")
        img?.isTemplate = true
        button?.image = img
        button?.toolTip = state == .needsAccess ? "Sidesnap needs screen access" : "Sidesnap"
    }
}
