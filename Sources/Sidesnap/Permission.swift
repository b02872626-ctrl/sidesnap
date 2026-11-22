import AppKit

/// Screen Recording permission. macOS decides it; Sidesnap can only ask and
/// point people to System Settings.
enum Permission {
    static var hasAccess: Bool { CGPreflightScreenCaptureAccess() }

    /// Asks macOS (shows the system prompt the first time) and opens the
    /// Screen Recording page in System Settings.
    static func openSettings() {
        _ = CGRequestScreenCaptureAccess()
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        NSWorkspace.shared.open(url)
    }

    /// Shown when a capture shortcut is pressed without access, so nothing
    /// blank ever lands on the shelf.
    static func showMissingAlert() {
        MenuIcon.shared.state = .needsAccess
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Sidesnap can't see your screen"
        alert.informativeText = "Screen access is turned off, so nothing was captured. Turn on Sidesnap in Privacy & Security › Screen Recording, then try again."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Not Now")
        if alert.runModal() == .alertFirstButtonReturn { openSettings() }
    }
}
