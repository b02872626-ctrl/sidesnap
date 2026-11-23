import AppKit
import SwiftUI
import Combine

/// The tab on the right screen edge. It shrinks to a sliver after 5 seconds
/// (or a click anywhere else), hides after 5 minutes, and comes back when the
/// pointer reaches the edge. Hovering it fans out recent screenshots upward.
final class EdgeModel: ObservableObject {
    @Published var items: [ShelfItem] = []      // newest first, at most 5
    @Published var images: [UUID: NSImage] = [:]
    @Published var total = 0
    @Published var spread = false
    @Published var copiedID: UUID?
    @Published var query = ""
    @Published var results: [ShelfItem] = []   // what the stack shows, newest first
    @Published var selected: Set<UUID> = []
    @Published var hoveredID: UUID?
    @Published var listHeight: CGFloat = 0     // the scrolling part of the stack
    var dragging = false
    @Published var pressedID: UUID?             // feedback the moment a card is pressed
}

/// A panel that can take typing (for the search field) without activating the app.
final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

final class EdgeTabController {
    enum Dock { case tab, sliver, hidden }

    static let tabSize = NSSize(width: 236, height: 172)   // as big as the stack items
    static let sliverVisible: CGFloat = 16
    static let fanWidth: CGFloat = 260
    static let itemHeight: CGFloat = 151   // same size as the corner card: 216 × 135
    static let thumbSize = CGSize(width: 216, height: 135)
    static let itemWidth: CGFloat = 236
    static let visibleItems: CGFloat = 7     // the stack shows about this many; scroll for older
    static let gap: CGFloat = 10

    private let store: ShelfStore
    private let model = EdgeModel()
    private var tabPanel: NSPanel!
    private var fanPanel: NSPanel!
    private var dock: Dock = .tab
    private var cardShowing = false
    private var fanShown = false
    private var screen: NSScreen = CaptureController.screenUnderMouse()
    private var idleTimers: [Timer] = []
    private var monitors: [Any] = []
    private var querySink: Any?
    private var selectionSink: Any?
    private var leaveTimer: Timer?
    /// How far outside the stack the pointer may wander, and for how long, before it closes.
    static let forgiveMargin: CGFloat = 48
    static let forgiveDelay: TimeInterval = 0.7
    var onEdit: ((ShelfItem) -> Void)?

    init(store: ShelfStore) { self.store = store }

    func start() {
        tabPanel = makePanel(EdgeTabView(model: model, onTap: { [weak self] in self?.copyLatest() }))
        fanPanel = makePanel(EdgeFanView(model: model, actions: FanActions(
            copy: { [weak self] in self?.copy($0) },
            edit: { [weak self] item in self?.clearSelection(); self?.hideFan(); self?.onEdit?(item) },
            save: { [weak self] items in items.forEach { _ = self?.store.saveToPictures($0) } },
            pin: { [weak self] items in
                let on = !items.allSatisfy(\.isPinned)
                items.forEach { self?.store.setPinned($0.id, on) }
            },
            revert: { [weak self] in self?.store.revert($0.id) },
            copyText: { [weak self] item in
                guard let self else { return }
                let near = self.fanPanel.isVisible ? self.fanPanel.frame : self.tabFrame(for: .tab)
                TextReader.text(of: item, store: self.store) { text in
                    if let text {
                        CaptureController.copyString(text)
                        TextHUD.show("Copied text", detail: String(text.prefix(80)), near: near)
                    } else {
                        TextHUD.show("No text found", detail: nil, near: near)
                    }
                }
            },
            remove: { [weak self] items in items.forEach { self?.store.remove($0) }; self?.clearSelection() },
            url: { [weak self] in self?.store.url(for: $0) },
            toggleSelect: { [weak self] in self?.toggleSelect($0) },
            selection: { [weak self] in self?.selectedItems() ?? [] },
            clearSelection: { [weak self] in self?.clearSelection() },
            close: { [weak self] in self?.closeSearch() })))
        querySink = model.$query.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.refreshResults(); if self?.fanShown == true { self?.layoutFan() } }
        }
        selectionSink = model.$selected.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { if self?.fanShown == true { self?.layoutFan() } }
        }
        NotificationCenter.default.addObserver(forName: ShelfStore.changed, object: nil, queue: .main) { [weak self] _ in
            self?.reload()
        }
        let moved: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        if let g = NSEvent.addGlobalMonitorForEvents(matching: moved, handler: { [weak self] _ in self?.pointerMoved() }) { monitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: moved, handler: { [weak self] e in self?.pointerMoved(); return e }) { monitors.append(l) }
        // A click in any other app counts as "clicked somewhere else".
        if let c = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in self?.clickedElsewhere() }) { monitors.append(c) }
        reload()
        touch()
    }

    func cardOpened() {
        cardShowing = true
        clearIdle()
        hideFan()
        tabPanel.orderOut(nil)
    }

    func cardClosed() {
        cardShowing = false
        screen = CaptureController.screenUnderMouse()
        touch()
    }

    // MARK: State

    private func reload() {
        model.total = store.items.count
        model.items = Array(store.items.prefix(5))
        // Thumbnails are cached in the store, so refilling after any change is cheap
        // and picks up edited pictures.
        model.images = [:]
        for item in store.items.prefix(1) { model.images[item.id] = store.thumbnail(for: item) }
        refreshResults()
        if fanShown { layoutFan() }
        apply(animated: false)
    }

    /// Any use restarts the idle timeline.
    private func touch() {
        clearIdle()
        setDock(.tab)
        // Timings come from Settings › General › Edge tab (0 = never).
        if Prefs.sliverAfter > 0 {
            idleTimers.append(Timer.scheduledTimer(withTimeInterval: TimeInterval(Prefs.sliverAfter), repeats: false) { [weak self] _ in
                self?.setDock(.sliver)
            })
        }
        if Prefs.hideAfter > 0 {
            idleTimers.append(Timer.scheduledTimer(withTimeInterval: TimeInterval(Prefs.hideAfter), repeats: false) { [weak self] _ in
                self?.setDock(.hidden)
            })
        }
    }

    private func clearIdle() {
        idleTimers.forEach { $0.invalidate() }
        idleTimers.removeAll()
    }

    private func setDock(_ d: Dock) {
        guard d != dock || !tabPanel.isVisible else { return }
        dock = d
        if d != .tab { hideFan() }
        apply(animated: true)
    }

    private func tabFrame(for d: Dock) -> NSRect {
        let vf = screen.visibleFrame
        let x: CGFloat
        switch d {
        case .tab: x = vf.maxX - Self.tabSize.width
        case .sliver: x = vf.maxX - Self.sliverVisible
        case .hidden: x = vf.maxX
        }
        return NSRect(x: x, y: vf.minY + 120, width: Self.tabSize.width, height: Self.tabSize.height)
    }

    private func apply(animated: Bool) {
        guard tabPanel != nil else { return }
        if cardShowing || store.items.isEmpty {
            tabPanel.orderOut(nil); hideFan(); return
        }
        let target = tabFrame(for: dock)
        if !tabPanel.isVisible {
            tabPanel.setFrame(tabFrame(for: .hidden), display: false)
            tabPanel.orderFrontRegardless()
        }
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if animated && !reduce {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.35
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)
                tabPanel.animator().setFrame(target, display: true)
                tabPanel.animator().alphaValue = dock == .hidden ? 0 : 1
            }
        } else {
            tabPanel.setFrame(target, display: true)
            tabPanel.alphaValue = dock == .hidden ? 0 : 1
        }
    }

    // MARK: Pointer

    private func pointerMoved() {
        guard !cardShowing, !store.items.isEmpty, tabPanel != nil else { return }
        let p = NSEvent.mouseLocation
        let full = tabFrame(for: .tab)
        switch dock {
        case .hidden, .sliver:
            // The strip along the edge near the tab brings it back.
            let edge = screen.frame.maxX
            let nearEdge = p.x >= edge - (dock == .hidden ? 3 : Self.sliverVisible) && p.x <= edge
            let band = full.insetBy(dx: 0, dy: dock == .hidden ? -100 : 0)
            if nearEdge && p.y >= band.minY && p.y <= band.maxY {
                clearIdle()
                setDock(.tab)
                showFan()
            }
        case .tab:
            let m = Self.forgiveMargin
            let overTab = full.contains(p)
            let nearTab = full.insetBy(dx: -m, dy: -m).contains(p)
            let nearFan = fanShown && fanPanel.frame.insetBy(dx: -m, dy: -m).contains(p)
            if overTab || nearFan || (fanShown && nearTab) {
                // Back in (or close enough): cancel any pending close.
                leaveTimer?.invalidate(); leaveTimer = nil
                clearIdle()
                if !fanShown && overTab { showFan() }
            } else if fanShown && model.query.isEmpty && model.selected.isEmpty && !model.dragging {
                // Outside: close only if the pointer stays away for a moment.
                if leaveTimer == nil {
                    leaveTimer = Timer.scheduledTimer(withTimeInterval: Self.forgiveDelay, repeats: false) { [weak self] _ in
                        guard let self else { return }
                        self.leaveTimer = nil
                        let q = NSEvent.mouseLocation
                        let back = self.fanPanel.frame.insetBy(dx: -m, dy: -m).contains(q)
                            || self.tabFrame(for: .tab).insetBy(dx: -m, dy: -m).contains(q)
                        if !back && self.model.selected.isEmpty && self.model.query.isEmpty && !self.model.dragging {
                            self.hideFan()
                            self.touch()
                        }
                    }
                }
            }
        }
    }

    private func clickedElsewhere() {
        if model.dragging { return }
        if dock == .tab && !cardShowing && Prefs.sliverAfter > 0 {
            model.query = ""
            model.selected = []
            hideFan()
            setDock(.sliver)
        }
    }

    private func toggleSelect(_ item: ShelfItem) {
        if model.selected.contains(item.id) { model.selected.remove(item.id) } else { model.selected.insert(item.id) }
    }

    private func clearSelection() { model.selected = [] }

    /// The selected screenshots, newest first.
    private func selectedItems() -> [ShelfItem] { store.items.filter { model.selected.contains($0.id) } }

    private func closeSearch() {
        model.selected = []
        model.query = ""
        hideFan()
        touch()
    }

    private func refreshResults() {
        let q = model.query.trimmingCharacters(in: .whitespaces)
        // Everything on the shelf (or every match); it scrolls when it's taller than the screen.
        let next = q.isEmpty ? store.items : store.items.filter { $0.matches(q) }
        // While the stack is open, removals and new arrivals glide instead of jumping.
        if fanShown && !Motion.reduce {
            withAnimation(Motion.settle) { model.results = next }
        } else {
            model.results = next
        }
        model.selected = model.selected.filter { id in store.items.contains { $0.id == id } }
        for item in model.results where model.images[item.id] == nil { model.images[item.id] = store.thumbnail(for: item) }
    }

    // MARK: Fan

    private func layoutFan() {
        let count = CGFloat(max(model.results.count, 1))
        let bar = model.selected.isEmpty ? 0 : 34 + Self.gap
        let tab = tabFrame(for: .tab)
        let vf = screen.visibleFrame
        // Always a whole number of cards, so none is ever shown cut in half.
        let row = Self.itemHeight + Self.gap
        let room = vf.maxY - tab.maxY - bar - 34 - Self.gap - 24
        let fit = max(1, min(Self.visibleItems, ((room + Self.gap) / row).rounded(.down)))
        let rows = min(count, fit)
        model.listHeight = rows * row - Self.gap
        let height = bar + 34 + Self.gap + model.listHeight + 4
        fanPanel.setFrame(NSRect(x: vf.maxX - Self.fanWidth, y: tab.maxY, width: Self.fanWidth, height: height), display: true)
    }

    private func showFan() {
        guard !model.items.isEmpty else { return }
        let wasClosing = fanPanel.isVisible     // reopened mid-close: carry on from where it is
        refreshResults()
        layoutFan()
        if !wasClosing { model.spread = false; fanPanel.alphaValue = 0 }
        fanPanel.orderFrontRegardless()
        fanShown = true
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Motion.reduce ? 0.12 : 0.18
            fanPanel.animator().alphaValue = 1
        }
        DispatchQueue.main.async {
            withAnimation(Motion.reduce ? .easeOut(duration: 0.15) : Motion.spread) { self.model.spread = true }
        }
    }

    private func hideFan() {
        // A pending "pointer left" close would otherwise fire later and pop the tab back out.
        leaveTimer?.invalidate(); leaveTimer = nil
        guard fanShown else { return }
        fanShown = false
        model.hoveredID = nil
        model.pressedID = nil
        // Close along the path it opened: the cards gather back toward the tab and fade.
        withAnimation(Motion.reduce ? .easeOut(duration: 0.12) : Motion.settle) { model.spread = false }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Motion.reduce ? 0.12 : 0.2
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            fanPanel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, !self.fanShown else { return }   // reopened meanwhile: keep it
            self.fanPanel.orderOut(nil)
        })
    }

    private func copyLatest() {
        if let first = store.items.first { copy([first]) }
    }

    private func copy(_ items: [ShelfItem]) {
        guard let item = items.first else { return }
        if items.count == 1 { store.copy(item) } else {
            ShelfStore.copyToClipboard(items.compactMap { store.image(for: $0) })
        }
        model.copiedID = item.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            if self?.model.copiedID == item.id { self?.model.copiedID = nil }
        }
    }

    private func makePanel<V: View>(_ view: V) -> NSPanel {
        let p = KeyPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = .floating
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = false
        // No .fullScreenAuxiliary on purpose: the tab and its stack never sit over
        // full-screen apps (videos, slides, games). The corner card still does.
        p.collectionBehavior = [.canJoinAllSpaces, .stationary]
        p.appearance = NSAppearance(named: .darkAqua)
        p.contentView = NSHostingView(rootView: view)
        return p
    }
}

private let leftRounded: CACornerMask = [.layerMinXMinYCorner, .layerMinXMaxYCorner]
private let allCorners: CACornerMask = [.layerMinXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMinYCorner, .layerMaxXMaxYCorner]

struct EdgeTabView: View {
    @ObservedObject var model: EdgeModel
    let onTap: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            if let first = model.items.first, let img = model.images[first.id] {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                    .frame(width: 216, height: 135)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5))
            }
            Text(model.copiedID != nil && model.copiedID == model.items.first?.id ? "Copied" : "\(model.total) on shelf")
                .font(.system(size: 12, weight: .semibold))
                .monospacedDigit()
        }
        .padding(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 10))
        .frame(width: EdgeTabController.tabSize.width, height: EdgeTabController.tabSize.height)
        .background(BlurBackground(cornerRadius: 12, corners: leftRounded))
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .help("Click to copy the latest screenshot. Hover to see recent ones.")
        .accessibilityLabel("Sidesnap, \(model.total) on shelf")
    }
}

struct FanActions {
    let copy: ([ShelfItem]) -> Void
    let edit: (ShelfItem) -> Void
    let save: ([ShelfItem]) -> Void
    let pin: ([ShelfItem]) -> Void
    let revert: (ShelfItem) -> Void
    let copyText: (ShelfItem) -> Void
    let remove: ([ShelfItem]) -> Void
    let url: (ShelfItem) -> URL?
    let toggleSelect: (ShelfItem) -> Void
    let selection: () -> [ShelfItem]
    let clearSelection: () -> Void
    let close: () -> Void

    /// What an action on this item applies to: the whole selection if it's part of one.
    func targets(_ item: ShelfItem) -> [ShelfItem] {
        let sel = selection()
        return sel.contains(where: { $0.id == item.id }) ? sel : [item]
    }
}

struct EdgeFanView: View {
    @ObservedObject var model: EdgeModel
    let actions: FanActions
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(alignment: .trailing, spacing: EdgeTabController.gap) {
            if !model.selected.isEmpty { selectionBar }

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.secondary)
                TextField("Search text in screenshots", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .focused($searchFocused)
                    .onExitCommand { actions.close() }
                if !model.query.isEmpty {
                    Button { model.query = "" } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 11)).foregroundStyle(.secondary)
                    }.buttonStyle(.plain).help("Clear search")
                }
            }
            .padding(.horizontal, 10)
            .frame(width: EdgeTabController.fanWidth - 8, height: 34)
            .background(BlurBackground(cornerRadius: 9))
            .opacity(model.spread ? 1 : 0)

            if !model.query.isEmpty && model.results.isEmpty {
                Text("No screenshot contains \u{201C}\(model.query)\u{201D}")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
                    .lineLimit(2).multilineTextAlignment(.trailing)
                    .padding(.horizontal, 10)
                    .frame(width: EdgeTabController.fanWidth - 8, height: EdgeTabController.itemHeight, alignment: .trailing)
            }

            // Oldest at the top, newest at the bottom next to the tab.
            // Scroll up for older ones; it opens scrolled to the newest.
            let list = Array(model.results.reversed())
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .trailing, spacing: EdgeTabController.gap) {
                    ForEach(Array(list.enumerated()), id: \.element.id) { index, item in
                        let fromBottom = CGFloat(list.count - 1 - index)
                        FanItem(item: item, image: model.images[item.id], copied: model.copiedID == item.id,
                                selected: model.selected.contains(item.id), hover: model.hoveredID == item.id,
                                pressed: model.pressedID == item.id,
                                model: model, actions: actions)
                            .offset(y: model.spread || fromBottom > 6 ? 0
                                    : fromBottom * (EdgeTabController.itemHeight + EdgeTabController.gap) + 16)
                            .opacity(model.spread ? 1 : 0)
                            .zIndex(Double(index))
                    }
                }
                .scrollTargetLayout()
                .frame(width: EdgeTabController.fanWidth, alignment: .trailing)
            }
            .defaultScrollAnchor(.bottom)
            .scrollTargetBehavior(.viewAligned)       // stops on whole cards
            .frame(width: EdgeTabController.fanWidth, height: model.listHeight)
            // While scrolling, cards fade out at the top and bottom instead of a hard cut.
            .mask(LinearGradient(stops: [.init(color: .clear, location: 0),
                                         .init(color: .black, location: edgeFade),
                                         .init(color: .black, location: 1 - edgeFade),
                                         .init(color: .clear, location: 1)],
                                 startPoint: .top, endPoint: .bottom))
        }
        .padding(.bottom, 4)
        .frame(width: EdgeTabController.fanWidth, alignment: .bottomTrailing)
        // Invisible, but not fully transparent: macOS sends scrolling over
        // see-through parts of a window to the app underneath, so without this
        // the gaps between cards scrolled the browser behind the stack.
        .background(Color.black.opacity(0.01))
    }

    /// Only the outer 6 px fade, so cards at rest look untouched.
    private var edgeFade: CGFloat { min(0.2, 6 / max(model.listHeight, 1)) }

    private var selectionBar: some View {
        let items = actions.selection()
        return HStack(spacing: 2) {
            Text("\(items.count) selected").font(.system(size: 12, weight: .semibold)).padding(.leading, 6)
            Spacer(minLength: 4)
            IconButton(symbol: "doc.on.doc", help: "Copy all", action: { actions.copy(items) })
            IconButton(symbol: "square.and.arrow.down", help: "Save all as files", action: { actions.save(items) })
            IconButton(symbol: items.allSatisfy(\.isPinned) ? "pin.slash" : "pin", help: "Pin or unpin", action: { actions.pin(items) })
            IconButton(symbol: "trash", help: "Remove from shelf", action: { actions.remove(items) })
            IconButton(symbol: "xmark", help: "Done", action: actions.clearSelection)
        }
        .padding(.horizontal, 4)
        .frame(width: EdgeTabController.fanWidth - 8, height: 34)
        .background(BlurBackground(cornerRadius: 9))
    }
}

struct FanItem: View {
    let item: ShelfItem
    let image: NSImage?
    let copied: Bool
    let selected: Bool
    let hover: Bool
    let pressed: Bool
    let model: EdgeModel
    let actions: FanActions

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                    .frame(width: EdgeTabController.thumbSize.width, height: EdgeTabController.thumbSize.height)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor, lineWidth: selected ? 2 : 0))
            }
            HStack(spacing: 3) {
                if selected {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 12))
                        .foregroundStyle(.white, Color.accentColor)
                }
                if item.isPinned {
                    Image(systemName: "pin.fill").font(.system(size: 8)).padding(3)
                        .background(Circle().fill(Color.black.opacity(0.7)))
                }
            }
            .offset(x: 2, y: 2)
            if copied {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 16)).foregroundStyle(.white)
                    .shadow(radius: 3).frame(width: EdgeTabController.thumbSize.width, height: EdgeTabController.thumbSize.height)
            }
        }
        .padding(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 10))
        .frame(width: EdgeTabController.itemWidth, height: EdgeTabController.itemHeight)
        .background(BlurBackground(cornerRadius: 12, corners: hover ? allCorners : leftRounded))
        // The one under the pointer slides out past the others.
        .offset(x: hover ? -16 : 0)
        .scaleEffect(pressed ? 0.97 : (hover ? 1.04 : 1), anchor: .trailing)
        .shadow(color: .black.opacity(hover ? 0.45 : 0), radius: 10, x: -2, y: 4)
        .zIndex(hover ? 10 : 0)
        // Hover carries no momentum, so no overshoot (critically damped).
        .animation(Motion.reduce ? nil : .spring(response: 0.25, dampingFraction: 1), value: hover)
        .animation(.easeOut(duration: 0.08), value: pressed)
        .transition(.asymmetric(insertion: .opacity,
                                removal: .opacity.combined(with: .move(edge: .trailing))))
        .overlay(ThumbEvents(item: item, image: image, model: model, actions: actions))
        // × to remove it from the shelf, shown while hovering. It sits above the
        // click/drag layer so it gets its own clicks.
        .overlay(alignment: .topTrailing) {
            if hover {
                Button { actions.remove([item]) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(Color.black.opacity(0.72)))
                        .overlay(Circle().strokeBorder(Color.white.opacity(0.25), lineWidth: 0.5))
                }
                .buttonStyle(.plain)
                .padding(.top, 13).padding(.trailing, 15)
                .help("Remove from shelf")
                .accessibilityLabel("Remove from shelf")
                .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }
        }
        .help("Click to copy, double-click to edit, ⌘-click to select several, drag into any app. Right-click for more.")
        .accessibilityLabel(item.title)
    }
}

/// Clicks, ⌘-clicks, double-clicks, right-clicks and dragging (one or many
/// screenshots at once) handled in AppKit, which SwiftUI can't do for several files.
struct ThumbEvents: NSViewRepresentable {
    let item: ShelfItem
    let image: NSImage?
    let model: EdgeModel
    let actions: FanActions

    func makeNSView(context: Context) -> ThumbEventView { ThumbEventView() }
    func updateNSView(_ v: ThumbEventView, context: Context) {
        v.item = item; v.image = image; v.model = model; v.actions = actions
    }
}

final class ThumbEventView: NSView, NSDraggingSource {
    var item: ShelfItem?
    var image: NSImage?
    var model: EdgeModel?
    var actions: FanActions?
    private var downPoint: NSPoint?
    private var dragStarted = false

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Scrolling over a card scrolls the stack, not whatever sits behind it.
    override func scrollWheel(with event: NSEvent) {
        if let sv = enclosingScrollView { sv.scrollWheel(with: event) } else { super.scrollWheel(with: event) }
    }

    // Hover is tracked here (always, even though the stack's window isn't
    // active), because this view sits on top and SwiftUI's hover never fires.
    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        // 24 px wider on the right: the gap left behind once it slides out still counts as hovering.
        let area = NSRect(x: 0, y: 0, width: bounds.width + 24, height: bounds.height)
        addTrackingArea(NSTrackingArea(rect: area, options: [.mouseEnteredAndExited, .activeAlways],
                                       owner: self, userInfo: nil))
    }
    override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); updateTrackingAreas() }
    override func mouseEntered(with event: NSEvent) { model?.hoveredID = item?.id }
    override func mouseExited(with event: NSEvent) {
        if model?.hoveredID == item?.id { model?.hoveredID = nil }
    }

    override func mouseDown(with event: NSEvent) {
        model?.pressedID = item?.id      // respond on press, not on release
        downPoint = event.locationInWindow
        dragStarted = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard !dragStarted, let start = downPoint, let item, let actions else { return }
        let p = event.locationInWindow
        guard hypot(p.x - start.x, p.y - start.y) > 3 else { return }
        dragStarted = true
        model?.pressedID = nil
        let targets = actions.targets(item)
        var dragItems: [NSDraggingItem] = []
        for (i, t) in targets.enumerated() {
            guard let url = actions.url(t) else { continue }
            let d = NSDraggingItem(pasteboardWriter: url as NSURL)
            let frame = NSRect(x: 8 + CGFloat(i) * 4, y: 8 - CGFloat(i) * 4, width: 216, height: 135)
            d.setDraggingFrame(frame, contents: model?.images[t.id] ?? image)
            dragItems.append(d)
        }
        guard !dragItems.isEmpty else { return }
        model?.dragging = true
        beginDraggingSession(with: dragItems, event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        if model?.pressedID == item?.id { model?.pressedID = nil }
        defer { downPoint = nil }
        guard !dragStarted, let item, let actions else { return }
        if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.shift) {
            actions.toggleSelect(item)
        } else if event.clickCount == 2 {
            actions.edit(item)
        } else if event.clickCount == 1 {
            if model?.selected.isEmpty == false { actions.toggleSelect(item) } else { actions.copy([item]) }
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let item, let actions else { return nil }
        let targets = actions.targets(item)
        let many = targets.count > 1
        let menu = NSMenu()
        func add(_ title: String, _ run: @escaping () -> Void) {
            let m = NSMenuItem(title: title, action: #selector(MenuAction.run), keyEquivalent: "")
            let box = MenuAction(run)
            m.target = box
            m.representedObject = box
            menu.addItem(m)
        }
        if !many { add("Edit") { actions.edit(item) } }
        add(many ? "Copy \(targets.count) Screenshots" : "Copy") { actions.copy(targets) }
        if !many { add("Copy Text") { actions.copyText(item) } }
        add(many ? "Save \(targets.count) as Files" : "Save as a File") { actions.save(targets) }
        add(targets.allSatisfy(\.isPinned) ? "Unpin" : "Pin") { actions.pin(targets) }
        if !many && (item.edited ?? false) { add("Revert to Original") { actions.revert(item) } }
        add(model?.selected.contains(item.id) == true ? "Deselect" : "Select") { actions.toggleSelect(item) }
        menu.addItem(.separator())
        add(many ? "Remove \(targets.count) from Shelf" : "Remove from Shelf") { actions.remove(targets) }
        return menu
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        model?.dragging = false
        dragStarted = false
    }
}

/// Lets a closure be the target of an NSMenuItem.
final class MenuAction: NSObject {
    private let block: () -> Void
    init(_ block: @escaping () -> Void) { self.block = block }
    @objc func run() { block() }
}
