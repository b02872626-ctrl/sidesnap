import AppKit
import Vision

/// One screenshot on the shelf.
struct ShelfItem: Codable, Identifiable, Equatable {
    let id: UUID
    let date: Date
    let kind: String      // "Area", "Window" or "Screen"
    let fileName: String
    var title: String
    var text: String?     // words read from the image on this Mac; nil until read
    var pinned: Bool?     // pinned screenshots are never cleared
    var edited: Bool?     // has marks that can still be changed in the editor

    var isPinned: Bool { pinned ?? false }

    /// True when the search words appear in its text or title.
    func matches(_ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces)
        if q.isEmpty { return true }
        return (text ?? "").localizedCaseInsensitiveContains(q) || title.localizedCaseInsensitiveContains(q)
    }
}

/// The marks on an edited screenshot, kept so they stay changeable.
struct SavedEdits: Codable {
    var marks: [Mark]
    var crop: CGRect?
}

/// Keeps screenshots in ~/Library/Application Support/Sidesnap/Shelf (never
/// on the Desktop) with a small JSON index. Nothing leaves this Mac.
final class ShelfStore {
    static let changed = Notification.Name("ShelfStoreChanged")

    private(set) var items: [ShelfItem] = []   // newest first
    let folder: URL
    private var cache: [UUID: NSImage] = [:]
    private var thumbs: [UUID: NSImage] = [:]
    private var indexURL: URL { folder.appendingPathComponent("index.json") }

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        folder = base.appendingPathComponent("Sidesnap/Shelf", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        load()
        removeOld()
        readMissingText()
    }

    func item(_ id: UUID) -> ShelfItem? { items.first { $0.id == id } }

    /// Replaces the picture (after editing) and reads its text again.
    func replaceImage(_ id: UUID, with cg: CGImage) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        let rep = NSBitmapImageRep(cgImage: cg)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: url(for: items[i]))
        cache[id] = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        thumbs[id] = nil
        items[i].text = nil
        save()
        readText(items[i])
    }

    func setPinned(_ id: UUID, _ on: Bool) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].pinned = on
        save()
    }

    /// Reads text for screenshots that don't have it yet (if text reading is on).
    func readMissingText() {
        for item in items where item.text == nil { readText(item) }
    }

    /// Removes every screenshot, optionally keeping pinned ones.
    func clear(keepPinned: Bool) {
        for item in items where !(keepPinned && item.isPinned) { remove(item) }
    }

    /// Reads the words in a screenshot with Apple's Vision, on this Mac only.
    private func readText(_ item: ShelfItem) {
        guard Prefs.readText, let img = image(for: item),
              let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            try? VNImageRequestHandler(cgImage: cg).perform([request])
            let words = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            let text = words.joined(separator: " ")
            DispatchQueue.main.async {
                guard let self, let i = self.items.firstIndex(where: { $0.id == item.id }) else { return }
                self.items[i].text = text
                self.save()
            }
        }
    }

    func url(for item: ShelfItem) -> URL { folder.appendingPathComponent(item.fileName) }

    func image(for item: ShelfItem) -> NSImage? {
        if let img = cache[item.id] { return img }
        let img = NSImage(contentsOf: url(for: item))
        cache[item.id] = img
        return img
    }

    /// A small version for the stack (fast to load, light on memory).
    func thumbnail(for item: ShelfItem) -> NSImage? {
        if let t = thumbs[item.id] { return t }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                     kCGImageSourceThumbnailMaxPixelSize: 300,
                                     kCGImageSourceCreateThumbnailWithTransform: true]
        guard let src = CGImageSourceCreateWithURL(url(for: item) as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        let t = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        thumbs[item.id] = t
        return t
    }

    /// Saves a capture as PNG and puts it first on the shelf.
    @discardableResult
    func add(_ cg: CGImage, kind: String, title: String) -> ShelfItem? {
        let rep = NSBitmapImageRep(cgImage: cg)
        guard let data = rep.representation(using: .png, properties: [:]) else { return nil }
        let name = uniqueFileName()
        do { try data.write(to: folder.appendingPathComponent(name)) } catch { return nil }
        let item = ShelfItem(id: UUID(), date: Date(), kind: kind, fileName: name, title: title)
        let img = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        cache[item.id] = img
        items.insert(item, at: 0)
        save()
        readText(item)
        return item
    }

    // MARK: Edits that stay changeable

    private var originalsFolder: URL { folder.appendingPathComponent("originals", isDirectory: true) }
    private var editsFolder: URL { folder.appendingPathComponent("edits", isDirectory: true) }
    private func originalURL(_ id: UUID) -> URL { originalsFolder.appendingPathComponent("\(id.uuidString).png") }
    private func editsURL(_ id: UUID) -> URL { editsFolder.appendingPathComponent("\(id.uuidString).json") }

    func original(_ id: UUID) -> CGImage? {
        NSImage(contentsOf: originalURL(id))?.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    func loadEdits(_ id: UUID) -> SavedEdits? {
        guard let data = try? Data(contentsOf: editsURL(id)) else { return nil }
        return try? JSONDecoder().decode(SavedEdits.self, from: data)
    }

    /// Keeps the untouched original and the marks, and shows the edited picture on the shelf.
    func saveEdits(_ id: UUID, original: CGImage, edits: SavedEdits, result: CGImage) {
        try? FileManager.default.createDirectory(at: originalsFolder, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: editsFolder, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: originalURL(id).path),
           let png = NSBitmapImageRep(cgImage: original).representation(using: .png, properties: [:]) {
            try? png.write(to: originalURL(id))
        }
        if let data = try? JSONEncoder().encode(edits) { try? data.write(to: editsURL(id)) }
        if let i = items.firstIndex(where: { $0.id == id }) { items[i].edited = !edits.marks.isEmpty || edits.crop != nil }
        replaceImage(id, with: result)
    }

    /// Puts the original back and drops all marks.
    func revert(_ id: UUID) {
        guard let orig = original(id) else { return }
        try? FileManager.default.removeItem(at: originalURL(id))
        try? FileManager.default.removeItem(at: editsURL(id))
        if let i = items.firstIndex(where: { $0.id == id }) { items[i].edited = false }
        replaceImage(id, with: orig)
    }

    func remove(_ item: ShelfItem) {
        try? FileManager.default.removeItem(at: originalURL(item.id))
        try? FileManager.default.removeItem(at: editsURL(item.id))
        try? FileManager.default.removeItem(at: url(for: item))
        items.removeAll { $0.id == item.id }
        cache[item.id] = nil
        thumbs[item.id] = nil
        save()
    }

    /// Puts the screenshot on the clipboard as an image.
    func copy(_ item: ShelfItem) {
        guard let img = image(for: item) else { return }
        Self.copyToClipboard(img)
    }

    static func copyToClipboard(_ img: NSImage) { copyToClipboard([img]) }

    /// Puts images on the clipboard as PNG and TIFF. Many apps (browsers,
    /// Telegram, Slack) only paste PNG, so TIFF alone looks like nothing was copied.
    static func copyToClipboard(_ images: [NSImage]) {
        let items: [NSPasteboardItem] = images.compactMap { img in
            guard let tiff = img.tiffRepresentation,
                  let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return nil }
            let item = NSPasteboardItem()
            item.setData(png, forType: .png)
            item.setData(tiff, forType: .tiff)
            return item
        }
        guard !items.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(items)
    }

    /// Copies the file to the save folder (Settings, default ~/Pictures/Sidesnap).
    @discardableResult
    func saveToPictures(_ item: ShelfItem) -> URL? {
        let pics = Prefs.saveFolder
        try? FileManager.default.createDirectory(at: pics, withIntermediateDirectories: true)
        let dest = pics.appendingPathComponent(item.fileName)
        try? FileManager.default.removeItem(at: dest)
        do { try FileManager.default.copyItem(at: url(for: item), to: dest) } catch { return nil }
        return dest
    }

    private func uniqueFileName() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let stem = "Sidesnap \(f.string(from: Date()))"
        var name = "\(stem).png"
        var n = 2
        while FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path) {
            name = "\(stem) (\(n)).png"; n += 1
        }
        return name
    }

    private func load() {
        guard let data = try? Data(contentsOf: indexURL),
              let list = try? JSONDecoder().decode([ShelfItem].self, from: data) else { return }
        items = list.filter { FileManager.default.fileExists(atPath: url(for: $0).path) }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(items) { try? data.write(to: indexURL) }
        NotificationCenter.default.post(name: Self.changed, object: self)
    }

    /// Clears screenshots older than the "Keep screenshots for" setting.
    func removeOld() {
        guard Prefs.keepDays > 0 else { return }
        let cutoff = Date().addingTimeInterval(-Double(Prefs.keepDays) * 86_400)
        for item in items where item.date < cutoff && !item.isPinned { remove(item) }
    }
}
