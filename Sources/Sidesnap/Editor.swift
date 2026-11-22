import AppKit
import SwiftUI
import CoreImage

// MARK: - Model

enum Tool: String, CaseIterable {
    case select, arrow, text, bubble, box, blur, highlight, pen, step, crop

    var key: String {
        switch self {
        case .select: return "V"
        case .arrow: return "A"
        case .text: return "T"
        case .bubble: return "U"
        case .box: return "R"
        case .blur: return "B"
        case .highlight: return "H"
        case .pen: return "P"
        case .step: return "N"
        case .crop: return "C"
        }
    }
    var name: String {
        switch self {
        case .select: return "Select"
        case .arrow: return "Arrow"
        case .text: return "Text"
        case .bubble: return "Speech bubble"
        case .box: return "Box"
        case .blur: return "Blur"
        case .highlight: return "Highlight"
        case .pen: return "Pen"
        case .step: return "Numbered step"
        case .crop: return "Crop"
        }
    }
    var symbol: String {
        switch self {
        case .select: return "cursorarrow"
        case .arrow: return "arrow.up.left"
        case .text: return "textformat"
        case .bubble: return "bubble.left"
        case .box: return "rectangle"
        case .blur: return "circle.grid.3x3"
        case .highlight: return "highlighter"
        case .pen: return "pencil.tip"
        case .step: return "1.circle"
        case .crop: return "crop"
        }
    }
}

enum MarkKind: String, Codable { case arrow, box, text, bubble, blur, highlight, pen, step }

/// One annotation, in image pixel coordinates (top-left origin).
struct Mark: Identifiable, Codable {
    var id = UUID()
    var kind: MarkKind
    var a: CGPoint
    var b: CGPoint
    var points: [CGPoint] = []
    var color: Int
    var size: Int          // 0 thin, 1 medium, 2 thick
    var text = ""
    var number = 0

    var rect: CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    mutating func move(by d: CGSize) {
        a.x += d.width; a.y += d.height
        b.x += d.width; b.y += d.height
        points = points.map { CGPoint(x: $0.x + d.width, y: $0.y + d.height) }
    }
}

enum Palette {
    static let colors: [Color] = [
        Color(red: 1, green: 0.23, blue: 0.19), Color(red: 1, green: 0.84, blue: 0.04),
        Color(red: 0.04, green: 0.52, blue: 1), .white, Color(white: 0.11)]
    static let names = ["Red", "Yellow", "Blue", "White", "Black"]
    static let hex = ["#FF3B30", "#FFD60A", "#0A84FF", "#FFFFFF", "#1D1D1F"]
    static let sizeNames = ["Thin", "Medium", "Thick"]
}

final class EditorModel: ObservableObject {
    let itemID: UUID
    let base: CGImage
    let pixelated: CGImage
    let pixelSize: CGSize
    let scale: CGFloat           // pixels per point (2 on Retina captures)
    /// One "point" of stroke in image pixels, so marks look the same on any capture.
    var unit: CGFloat { scale }

    @Published var marks: [Mark] = []
    @Published var crop: CGRect?
    @Published var tool: Tool = .arrow
    @Published var color = 0
    @Published var size = 1
    @Published var selected: UUID?
    @Published var draft: Mark?
    @Published var cropDraft: CGRect?
    @Published var editingText: UUID?
    @Published var hoverHex = "—"
    @Published var zoom: CGFloat = 1
    @Published var note: String?
    @Published var pinned: Bool
    var dirty = false

    private var undoStack: [([Mark], CGRect?)] = []
    private let rep: NSBitmapImageRep

    init(item: ShelfItem, image: CGImage, pointWidth: CGFloat) {
        itemID = item.id
        base = image
        pixelSize = CGSize(width: image.width, height: image.height)
        scale = max(1, CGFloat(image.width) / max(pointWidth, 1))
        pixelated = Self.pixelate(image)
        rep = NSBitmapImageRep(cgImage: image)
        pinned = item.isPinned
    }

    var nextStep: Int { (marks.filter { $0.kind == .step }.map(\.number).max() ?? 0) + 1 }

    func snapshot() {
        undoStack.append((marks, crop))
        if undoStack.count > 100 { undoStack.removeFirst() }
        dirty = true
    }

    func undo() {
        guard let last = undoStack.popLast() else { return }
        marks = last.0
        crop = last.1
        selected = nil
    }

    func deleteSelected() {
        guard let id = selected else { return }
        snapshot()
        marks.removeAll { $0.id == id }
        selected = nil
    }

    func setColor(_ c: Int) {
        color = c
        if let id = selected, let i = marks.firstIndex(where: { $0.id == id }) {
            snapshot(); marks[i].color = c
        }
    }

    func setSize(_ s: Int) {
        size = s
        if let id = selected, let i = marks.firstIndex(where: { $0.id == id }) {
            snapshot(); marks[i].size = s
        }
    }

    func hit(_ p: CGPoint) -> UUID? {
        let pad = 8 * unit
        for m in marks.reversed() {
            var r: CGRect
            switch m.kind {
            case .pen:
                let xs = m.points.map(\.x), ys = m.points.map(\.y)
                r = CGRect(x: xs.min() ?? 0, y: ys.min() ?? 0,
                           width: (xs.max() ?? 0) - (xs.min() ?? 0), height: (ys.max() ?? 0) - (ys.min() ?? 0))
            case .text, .bubble:
                r = textBox(m)
            case .step:
                let rad = Self.stepRadius(m.size) * unit
                r = CGRect(x: m.a.x - rad, y: m.a.y - rad, width: rad * 2, height: rad * 2)
            default:
                r = m.rect
            }
            if r.insetBy(dx: -pad, dy: -pad).contains(p) { return m.id }
        }
        return nil
    }

    func hex(at p: CGPoint) -> String {
        let x = Int(p.x), y = Int(p.y)
        guard x >= 0, y >= 0, x < rep.pixelsWide, y < rep.pixelsHigh,
              let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return "—" }
        return String(format: "#%02X%02X%02X", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
    }

    static func strokeWidth(_ s: Int) -> CGFloat { [2, 4, 7][s] }

    /// Size of a text or bubble box (several lines allowed), in image pixels.
    static func textBoxSize(_ text: String, size: Int, unit: CGFloat) -> CGSize {
        let fs = fontSize(size) * unit
        let str = (text.isEmpty ? " " : text) as NSString
        let r = str.boundingRect(with: CGSize(width: 100_000, height: 100_000), options: [.usesLineFragmentOrigin],
                                 attributes: [.font: NSFont.systemFont(ofSize: fs, weight: .bold)])
        return CGSize(width: ceil(r.width) + fs * 0.9, height: ceil(r.height) + fs * 0.5)
    }

    /// Where the words sit: a text label at its point, a bubble at its box (the point is the tail).
    func textBox(_ m: Mark, text: String? = nil) -> CGRect {
        let origin = m.kind == .bubble ? m.b : m.a
        return CGRect(origin: origin, size: Self.textBoxSize(text ?? m.text, size: m.size, unit: unit))
    }
    static func fontSize(_ s: Int) -> CGFloat { [13, 18, 26][s] }
    static func stepRadius(_ s: Int) -> CGFloat { [10, 13, 17][s] }

    static func pixelate(_ cg: CGImage) -> CGImage {
        let input = CIImage(cgImage: cg)
        let f = CIFilter(name: "CIPixellate")!
        f.setValue(input.clampedToExtent(), forKey: kCIInputImageKey)
        f.setValue(max(10, CGFloat(cg.width) / 70), forKey: kCIInputScaleKey)
        let ctx = CIContext()
        return f.outputImage.flatMap { ctx.createCGImage($0, from: input.extent) } ?? cg
    }

    /// The finished picture: base + marks, cropped if a crop is set.
    @MainActor
    func render() -> CGImage? {
        let view = MarkupLayer(model: self, showUI: false)
            .frame(width: pixelSize.width, height: pixelSize.height)
        let r = ImageRenderer(content: view)
        r.scale = 1
        guard let full = r.cgImage else { return nil }
        if let c = crop?.integral, c.width > 4, c.height > 4 { return full.cropping(to: c) ?? full }
        return full
    }
}

// MARK: - Drawing (shared by the screen and the export)

struct MarkupLayer: View {
    @ObservedObject var model: EditorModel
    var showUI: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            Image(decorative: model.base, scale: 1)
                .resizable()
            Canvas { ctx, size in
                let k = size.width / model.pixelSize.width
                ctx.scaleBy(x: k, y: k)
                var all = model.marks
                if let d = model.draft { all.append(d) }
                for m in all where m.kind == .blur { drawBlur(m, &ctx) }
                for m in all where m.kind != .blur && !(showUI && m.id == model.editingText) { draw(m, &ctx) }
                if showUI {
                    if let id = model.selected, let m = model.marks.first(where: { $0.id == id }) { drawSelection(m, &ctx) }
                    if let c = model.cropDraft ?? model.crop { drawCrop(c, &ctx) }
                }
            }
        }
    }

    private var u: CGFloat { model.unit }

    private func drawBlur(_ m: Mark, _ ctx: inout GraphicsContext) {
        ctx.drawLayer { layer in
            layer.clip(to: Path(roundedRect: m.rect, cornerRadius: 4 * u))
            layer.draw(Image(decorative: model.pixelated, scale: 1),
                       in: CGRect(origin: .zero, size: model.pixelSize))
        }
    }

    private func draw(_ m: Mark, _ ctx: inout GraphicsContext) {
        let color = Palette.colors[m.color]
        let w = EditorModel.strokeWidth(m.size) * u
        let style = StrokeStyle(lineWidth: w, lineCap: .round, lineJoin: .round)
        switch m.kind {
        case .box:
            ctx.stroke(Path(roundedRect: m.rect, cornerRadius: 4 * u), with: .color(color), style: style)
        case .highlight:
            ctx.fill(Path(m.rect), with: .color(color.opacity(0.4)))
        case .arrow:
            let angle = atan2(m.b.y - m.a.y, m.b.x - m.a.x)
            let head = max(w * 4, 12 * u)
            var p = Path()
            p.move(to: m.a); p.addLine(to: m.b)
            p.move(to: CGPoint(x: m.b.x - head * cos(angle - 0.5), y: m.b.y - head * sin(angle - 0.5)))
            p.addLine(to: m.b)
            p.addLine(to: CGPoint(x: m.b.x - head * cos(angle + 0.5), y: m.b.y - head * sin(angle + 0.5)))
            ctx.stroke(p, with: .color(.white.opacity(0.85)), style: StrokeStyle(lineWidth: w + 2 * u, lineCap: .round, lineJoin: .round))
            ctx.stroke(p, with: .color(color), style: style)
        case .pen:
            guard let first = m.points.first else { return }
            var p = Path()
            p.move(to: first)
            for pt in m.points.dropFirst() { p.addLine(to: pt) }
            ctx.stroke(p, with: .color(color), style: style)
        case .text, .bubble:
            let fs = EditorModel.fontSize(m.size) * u
            let fg: Color = m.color == 3 ? .black : .white
            let box = model.textBox(m)
            var shape = Path(roundedRect: box, cornerRadius: fs * (m.kind == .bubble ? 0.6 : 0.3))
            if m.kind == .bubble { shape.addPath(Self.tail(from: box, to: m.a, width: fs * 0.9)) }
            ctx.fill(shape, with: .color(color))
            let t = ctx.resolve(Text(m.text.isEmpty ? " " : m.text).font(.system(size: fs, weight: .bold)).foregroundColor(fg))
            ctx.draw(t, at: CGPoint(x: box.minX + fs * 0.45, y: box.minY + fs * 0.25), anchor: .topLeading)
        case .step:
            let r = EditorModel.stepRadius(m.size) * u
            let c = CGRect(x: m.a.x - r, y: m.a.y - r, width: r * 2, height: r * 2)
            ctx.fill(Path(ellipseIn: c), with: .color(color))
            ctx.stroke(Path(ellipseIn: c), with: .color(.white), lineWidth: 1.5 * u)
            let fg: Color = m.color == 3 ? .black : .white
            let t = ctx.resolve(Text("\(m.number)").font(.system(size: r * 1.1, weight: .bold)).foregroundColor(fg))
            ctx.draw(t, at: m.a, anchor: .center)
        case .blur:
            break
        }
    }

    /// The little triangle from a bubble's edge to the point it talks about.
    static func tail(from box: CGRect, to tip: CGPoint, width: CGFloat) -> Path {
        var p = Path()
        if box.contains(tip) { return p }
        let half = width / 2
        let a: CGPoint, b: CGPoint
        if tip.y > box.maxY || tip.y < box.minY {
            let y = tip.y > box.maxY ? box.maxY - 1 : box.minY + 1
            let x = min(max(tip.x, box.minX + width), box.maxX - width)
            a = CGPoint(x: x - half, y: y); b = CGPoint(x: x + half, y: y)
        } else {
            let x = tip.x < box.minX ? box.minX + 1 : box.maxX - 1
            let y = min(max(tip.y, box.minY + width), box.maxY - width)
            a = CGPoint(x: x, y: y - half); b = CGPoint(x: x, y: y + half)
        }
        p.move(to: a); p.addLine(to: tip); p.addLine(to: b); p.closeSubpath()
        return p
    }

    private func drawSelection(_ m: Mark, _ ctx: inout GraphicsContext) {
        var r: CGRect
        switch m.kind {
        case .step:
            let rad = EditorModel.stepRadius(m.size) * u
            r = CGRect(x: m.a.x - rad, y: m.a.y - rad, width: rad * 2, height: rad * 2)
        case .text, .bubble:
            r = model.textBox(m)
        case .pen:
            let xs = m.points.map(\.x), ys = m.points.map(\.y)
            r = CGRect(x: xs.min() ?? 0, y: ys.min() ?? 0, width: (xs.max() ?? 0) - (xs.min() ?? 0), height: (ys.max() ?? 0) - (ys.min() ?? 0))
        default:
            r = m.rect
        }
        r = r.insetBy(dx: -5 * u, dy: -5 * u)
        ctx.stroke(Path(r), with: .color(.white), style: StrokeStyle(lineWidth: 1.2 * u, dash: [4 * u, 3 * u]))
    }

    private func drawCrop(_ c: CGRect, _ ctx: inout GraphicsContext) {
        var outside = Path(CGRect(origin: .zero, size: model.pixelSize))
        outside.addRect(c)
        ctx.fill(outside, with: .color(.black.opacity(0.55)), style: FillStyle(eoFill: true))
        ctx.stroke(Path(c), with: .color(.white), lineWidth: 1.5 * u)
    }
}

// MARK: - Window

final class EditorController: NSObject, NSWindowDelegate {
    private let store: ShelfStore
    private var windows: [UUID: NSWindow] = [:]
    private var models: [ObjectIdentifier: EditorModel] = [:]
    private var monitor: Any?

    init(store: ShelfStore) { self.store = store }

    func open(_ item: ShelfItem) {
        if let w = windows[item.id] { NSApp.activate(ignoringOtherApps: true); w.makeKeyAndOrderFront(nil); return }
        guard let ns = store.image(for: item),
              let cg = ns.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        let screen = CaptureController.screenUnderMouse()
        let pointWidth = CGFloat(cg.width) / screen.backingScaleFactor
        // Reopening an edited screenshot starts from the original with its marks
        // still movable, not from the flattened picture.
        let base = store.original(item.id) ?? cg
        let model = EditorModel(item: item, image: base, pointWidth: pointWidth)
        if let saved = store.loadEdits(item.id) {
            model.marks = saved.marks
            model.crop = saved.crop
        }

        let imgPts = CGSize(width: CGFloat(cg.width) / model.scale, height: CGFloat(cg.height) / model.scale)
        let vf = screen.visibleFrame
        let maxW = vf.width * 0.85, maxH = vf.height * 0.85 - 38
        let fit = min(1, maxW / imgPts.width, maxH / imgPts.height)
        let size = NSSize(width: max(760, imgPts.width * fit), height: max(420, imgPts.height * fit + 38))

        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.title = "Edit · \(item.title)"
        w.isReleasedWhenClosed = false
        w.appearance = NSAppearance(named: .darkAqua)
        w.backgroundColor = .black
        w.delegate = self
        w.contentView = NSHostingView(rootView: EditorView(model: model, actions: EditorActions(
            copy: { [weak self, weak model] in if let model { self?.copy(model) } },
            save: { [weak self, weak model] in if let model { self?.save(model) } },
            pin: { [weak self, weak model] in if let model { self?.togglePin(model) } },
            copyText: { [weak self, weak model] in if let model { self?.copyText(model) } })))
        w.center()
        windows[item.id] = w
        models[ObjectIdentifier(w)] = model
        installMonitor()
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    // MARK: Actions

    private func bake(_ model: EditorModel) -> CGImage? {
        // Always called from the main thread (buttons, keys, closing the window).
        guard let out = MainActor.assumeIsolated({ model.render() }) else { return nil }
        if model.dirty {
            store.saveEdits(model.itemID, original: model.base,
                            edits: SavedEdits(marks: model.marks, crop: model.crop), result: out)
            model.dirty = false
        }
        return out
    }

    private func copy(_ model: EditorModel) {
        guard let out = bake(model) else { return }
        ShelfStore.copyToClipboard(NSImage(cgImage: out, size: NSSize(width: CGFloat(out.width) / model.scale, height: CGFloat(out.height) / model.scale)))
        flash(model, "Copied")
    }

    private func save(_ model: EditorModel) {
        _ = bake(model)
        guard let item = store.item(model.itemID) else { return }
        flash(model, store.saveToPictures(item) == nil ? "Couldn't save" : "Saved")
    }

    /// Copies the words in the screenshot (the original, so marks don't get in the way).
    private func copyText(_ model: EditorModel) {
        TextReader.read(model.base) { [weak self, weak model] found in
            guard let model else { return }
            switch found {
            case let .text(t), let .qr(t):
                CaptureController.copyString(t)
                self?.flash(model, "Copied text")
            case .nothing:
                self?.flash(model, "No text found")
            }
        }
    }

    private func togglePin(_ model: EditorModel) {
        model.pinned.toggle()
        store.setPinned(model.itemID, model.pinned)
        flash(model, model.pinned ? "Pinned. It won't be cleared." : "Unpinned")
    }

    private func flash(_ model: EditorModel, _ text: String) {
        model.note = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { [weak model] in
            if model?.note == text { model?.note = nil }
        }
    }

    // MARK: Keys

    private func installMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, let w = NSApp.keyWindow, let model = self.models[ObjectIdentifier(w)] else { return e }
            // While a text box is open, every key is typing, never a tool shortcut.
            if model.editingText != nil || w.firstResponder is NSText || w.firstResponder is NSTextField { return e }
            return self.handleKey(e, model, w) ? nil : e
        }
    }

    private func handleKey(_ e: NSEvent, _ model: EditorModel, _ w: NSWindow) -> Bool {
        let cmd = e.modifierFlags.contains(.command)
        let ch = (e.charactersIgnoringModifiers ?? "").lowercased()
        if cmd {
            switch ch {
            case "c": if e.modifierFlags.contains(.shift) { copyText(model) } else { copy(model) }
            case "s": save(model)
            case "z": model.undo()
            case "p": togglePin(model)
            case "w": w.performClose(nil)
            default: return false
            }
            return true
        }
        switch e.keyCode {
        case 51, 117: model.deleteSelected(); return true          // Delete
        case 53:                                                   // Esc
            if model.cropDraft != nil { model.cropDraft = nil } else { model.selected = nil }
            return true
        case 48:                                                   // Tab: copy picked color
            let pb = NSPasteboard.general
            pb.clearContents(); pb.setString(model.hoverHex, forType: .string)
            flash(model, "Copied \(model.hoverHex)")
            return true
        default: break
        }
        if let tool = Tool.allCases.first(where: { $0.key.lowercased() == ch }) {
            model.tool = tool
            if tool != .select { model.selected = nil }
            return true
        }
        return false
    }

    // MARK: Closing keeps your edits

    func windowWillClose(_ n: Notification) {
        guard let w = n.object as? NSWindow, let model = models[ObjectIdentifier(w)] else { return }
        if model.dirty { _ = bake(model) }
        models[ObjectIdentifier(w)] = nil
        windows[model.itemID] = nil
    }
}

// MARK: - Editor view

struct EditorActions {
    let copy: () -> Void
    let save: () -> Void
    let pin: () -> Void
    let copyText: () -> Void
}

struct EditorView: View {
    @ObservedObject var model: EditorModel
    let actions: EditorActions

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            GeometryReader { geo in
                let k = min(geo.size.width / model.pixelSize.width, geo.size.height / model.pixelSize.height,
                            1 / model.scale)
                let shown = CGSize(width: model.pixelSize.width * k, height: model.pixelSize.height * k)
                ZStack {
                    Color.black
                    EditorCanvas(model: model, displayScale: k)
                        .frame(width: shown.width, height: shown.height)
                }
                .onAppear { model.zoom = k * model.scale }
                .onChange(of: geo.size) { _, _ in model.zoom = k * model.scale }
            }
        }
        .background(Color.black)
    }

    private var toolbar: some View {
        HStack(spacing: 2) {
            Color.clear.frame(width: 70, height: 1)    // traffic lights
            ToolButton(symbol: "doc.on.doc", label: "Copy", key: "⌘C", on: false, action: actions.copy)
            ToolButton(symbol: "square.and.arrow.down", label: "Save as a file", key: "⌘S", on: false, action: actions.save)
            ToolButton(symbol: model.pinned ? "pin.fill" : "pin", label: "Pin", key: "⌘P", on: model.pinned, action: actions.pin)
            ToolButton(symbol: "text.viewfinder", label: "Copy Text", key: "⇧⌘C", on: false, action: actions.copyText)
            divider
            ForEach(Tool.allCases, id: \.self) { t in
                ToolButton(symbol: t.symbol, label: t.name, key: t.key, on: model.tool == t) {
                    model.tool = t
                    if t != .select { model.selected = nil }
                }
            }
            divider
            Menu {
                ForEach(0..<Palette.colors.count, id: \.self) { i in
                    Button(Palette.names[i]) { model.setColor(i) }
                }
            } label: {
                Circle().fill(Palette.colors[model.color]).frame(width: 13, height: 13)
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.8), lineWidth: 1.5))
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 30, height: 28)
            .help("Color")
            Menu {
                ForEach(0..<3, id: \.self) { i in Button(Palette.sizeNames[i]) { model.setSize(i) } }
            } label: {
                RoundedRectangle(cornerRadius: 2).fill(Color.secondary).frame(width: 14, height: [1.5, 3, 5][model.size])
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 30, height: 28)
            .help("Thickness")
            ToolButton(symbol: "arrow.uturn.backward", label: "Undo", key: "⌘Z", on: false, action: model.undo)

            Spacer(minLength: 8)
            if let note = model.note {
                Text(note).font(.system(size: 11.5, weight: .medium)).foregroundStyle(.secondary)
                    .transition(.opacity)
            }
            readout(model.hoverHex, "Tab to copy")
            readout("\(Int(model.pixelSize.width / model.scale))×\(Int(model.pixelSize.height / model.scale))", "Image size")
            readout("\(Int((model.zoom * 100).rounded()))%", "Zoom")
        }
        .padding(.trailing, 12)
        .frame(height: 38)
        .background(WindowDragArea().background(Color(white: 0.11)))
        .overlay(Rectangle().fill(Color.white.opacity(0.08)).frame(height: 0.5), alignment: .bottom)
    }

    private var divider: some View {
        Rectangle().fill(Color.white.opacity(0.12)).frame(width: 1, height: 16).padding(.horizontal, 6)
    }

    private func readout(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value).font(.system(size: 10.5, weight: .semibold)).monospacedDigit()
            Text(label).font(.system(size: 9.5)).foregroundStyle(.secondary)
        }
        .frame(minWidth: 58, alignment: .leading)
    }
}

struct ToolButton: View {
    let symbol: String
    let label: String
    let key: String
    let on: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13)).frame(width: 30, height: 28)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(on ? 0.16 : (hover ? 0.08 : 0))))
        }
        .buttonStyle(.plain)
        .foregroundStyle(on ? .primary : .secondary)
        .onHover { hover = $0 }
        .help("\(label)  \(key)")
        .accessibilityLabel(label)
    }
}

/// Lets the toolbar's empty space move the window, like a title bar.
struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    }
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

// MARK: - Canvas with gestures

struct EditorCanvas: View {
    @ObservedObject var model: EditorModel
    let displayScale: CGFloat
    @State private var dragStart: CGPoint?
    @State private var moving: UUID?
    @State private var lastMove: CGPoint?
    @State private var textValue = ""
    @State private var closedTextThisClick = false
    @FocusState private var textFocused: Bool

    private func toPixels(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x / displayScale, y: p.y / displayScale) }

    var body: some View {
        // The text box sits beside the drawing layer, not inside it, so the
        // drawing gesture never steals its clicks or keyboard focus.
        ZStack(alignment: .topLeading) {
            MarkupLayer(model: model, showUI: true)
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    if case let .active(p) = phase { model.hoverHex = model.hex(at: toPixels(p)) }
                }
                .gesture(DragGesture(minimumDistance: 0).onChanged(changed).onEnded(ended))
            if let id = model.editingText, let m = model.marks.first(where: { $0.id == id }) {
                let fs = EditorModel.fontSize(m.size) * model.unit * displayScale
                let box = model.textBox(m, text: textValue + " ")
                let fg: Color = m.color == 3 ? .black : .white
                ZStack(alignment: .topLeading) {
                    if m.kind == .bubble {
                        MarkupLayer.tail(from: CGRect(x: box.minX * displayScale, y: box.minY * displayScale,
                                                      width: box.width * displayScale, height: box.height * displayScale),
                                         to: CGPoint(x: m.a.x * displayScale, y: m.a.y * displayScale), width: fs * 0.9)
                            .fill(Palette.colors[m.color])
                    }
                    // A normal multi-line box: Return starts a new line,
                    // Esc or a click elsewhere finishes.
                    TextEditor(text: $textValue)
                        .font(.system(size: fs, weight: .bold))
                        .foregroundStyle(fg)
                        .scrollContentBackground(.hidden)
                        .scrollDisabled(true)
                        .padding(.leading, fs * 0.45 - 5).padding(.top, fs * 0.25)
                        .frame(width: box.width * displayScale + fs, height: box.height * displayScale)
                        .background(RoundedRectangle(cornerRadius: fs * (m.kind == .bubble ? 0.6 : 0.3)).fill(Palette.colors[m.color]))
                        .offset(x: box.minX * displayScale, y: box.minY * displayScale)
                        .focused($textFocused)
                        .onExitCommand { finishText() }
                }
                .onAppear {
                    textValue = m.text
                    // Focus after the box is on screen, or macOS ignores it.
                    DispatchQueue.main.async { textFocused = true }
                }
                .id(id)
            }
        }
        .onChange(of: model.editingText) { _, new in if new == nil { textFocused = false } }
        .onChange(of: model.tool) { _, _ in if model.editingText != nil { finishText() } }
    }

    private func finishText() {
        guard let id = model.editingText, let i = model.marks.firstIndex(where: { $0.id == id }) else { return }
        let t = textValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { model.marks.remove(at: i) } else { model.marks[i].text = t }
        model.editingText = nil
        model.dirty = true
    }

    private func changed(_ v: DragGesture.Value) {
        let p = toPixels(v.location)
        if model.editingText != nil { finishText(); closedTextThisClick = true }
        if dragStart == nil {
            dragStart = toPixels(v.startLocation)
            if model.tool == .select {
                moving = model.hit(dragStart!)
                model.selected = moving
                if moving != nil { model.snapshot() }
                lastMove = dragStart
            }
        }
        guard let s = dragStart else { return }
        switch model.tool {
        case .select:
            if let id = moving, let i = model.marks.firstIndex(where: { $0.id == id }), let last = lastMove {
                model.marks[i].move(by: CGSize(width: p.x - last.x, height: p.y - last.y))
                lastMove = p
            }
        case .arrow: model.draft = Mark(kind: .arrow, a: s, b: p, color: model.color, size: model.size)
        case .box: model.draft = Mark(kind: .box, a: s, b: p, color: model.color, size: model.size)
        case .blur: model.draft = Mark(kind: .blur, a: s, b: p, color: model.color, size: model.size)
        case .highlight: model.draft = Mark(kind: .highlight, a: s, b: p, color: 1, size: model.size)
        case .pen:
            if model.draft == nil { model.draft = Mark(kind: .pen, a: s, b: s, points: [s], color: model.color, size: model.size) }
            model.draft?.points.append(p)
        case .crop:
            model.cropDraft = CGRect(x: min(s.x, p.x), y: min(s.y, p.y), width: abs(p.x - s.x), height: abs(p.y - s.y))
        case .text, .step, .bubble:
            break
        }
    }

    private func ended(_ v: DragGesture.Value) {
        let p = toPixels(v.location)
        defer { dragStart = nil; moving = nil; lastMove = nil; closedTextThisClick = false }
        // A click that only closed an open text box shouldn't start another one.
        if closedTextThisClick && [.text, .bubble].contains(model.tool) { return }
        switch model.tool {
        case .text:
            if let hit = model.hit(p), let m = model.marks.first(where: { $0.id == hit }), m.kind == .text {
                model.editingText = hit
            } else {
                model.snapshot()
                let m = Mark(kind: .text, a: p, b: p, color: model.color, size: model.size)
                model.marks.append(m)
                model.editingText = m.id
            }
        case .bubble:
            let start = toPixels(v.startLocation)
            let u = model.unit
            if let hit = model.hit(start), let m = model.marks.first(where: { $0.id == hit }), m.kind == .bubble {
                model.editingText = hit
                break
            }
            // Drag from the thing you point at to where the bubble goes; a plain click puts it up and right.
            let dragged = hypot(p.x - start.x, p.y - start.y) > 12 * u
            let spot = dragged ? p : CGPoint(x: start.x + 24 * u, y: start.y - 60 * u)
            model.snapshot()
            let m = Mark(kind: .bubble, a: start, b: spot, color: model.color, size: model.size)
            model.marks.append(m)
            model.editingText = m.id
        case .step:
            model.snapshot()
            model.marks.append(Mark(kind: .step, a: p, b: p, color: model.color, size: model.size, number: model.nextStep))
        case .crop:
            if let c = model.cropDraft, c.width > 8, c.height > 8 { model.snapshot(); model.crop = c }
            model.cropDraft = nil
        case .select:
            break
        default:
            if let d = model.draft {
                let big = d.kind == .pen ? d.points.count > 2 : (d.rect.width > 4 || d.rect.height > 4)
                if big { model.snapshot(); model.marks.append(d); model.selected = nil }
            }
            model.draft = nil
        }
    }
}
