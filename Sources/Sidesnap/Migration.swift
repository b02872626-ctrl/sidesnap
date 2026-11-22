import Foundation

/// Sidesnap used to be called Snapshelf (bundle ID app.snapshelf.mac). On the
/// first launch under the new name, bring over the shelf (screenshots, edits,
/// originals) and the settings, so nothing is lost. Runs once, before anything
/// else reads them.
enum Migration {
    private static let doneKey = "migratedFromSnapshelf"

    static func run() {
        let d = UserDefaults.standard
        guard !d.bool(forKey: doneKey) else { return }
        defer { d.set(true, forKey: doneKey) }

        // Settings (shortcuts, edge tab timing, after-capture choices...).
        if let old = UserDefaults(suiteName: "app.snapshelf.mac")?.persistentDomain(forName: "app.snapshelf.mac") {
            for (key, value) in old where d.object(forKey: key) == nil
                && !key.hasPrefix("NS") && !key.hasPrefix("Apple") && !key.hasPrefix("com.apple") {
                d.set(value, forKey: key)
            }
        }

        // The shelf folder in Application Support.
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let oldDir = support.appendingPathComponent("Snapshelf", isDirectory: true)
        let newDir = support.appendingPathComponent("Sidesnap", isDirectory: true)
        if fm.fileExists(atPath: oldDir.path) && !fm.fileExists(atPath: newDir.path) {
            try? fm.moveItem(at: oldDir, to: newDir)
        }

        // Saved files went to ~/Pictures/Snapshelf by default. Keep using that
        // folder if it exists and no other folder was chosen, so files stay together.
        if d.string(forKey: Prefs.Key.saveFolder) == nil {
            let pics = fm.urls(for: .picturesDirectory, in: .userDomainMask)[0]
            let oldPics = pics.appendingPathComponent("Snapshelf", isDirectory: true)
            let newPics = pics.appendingPathComponent("Sidesnap", isDirectory: true)
            if fm.fileExists(atPath: oldPics.path) && !fm.fileExists(atPath: newPics.path) {
                try? fm.moveItem(at: oldPics, to: newPics)
            }
        }
    }
}
