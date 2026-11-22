import AppKit
import SwiftUI

/// The card in the screen corner after a capture. It flies in from where the
/// screenshot was taken and stays until its × is pressed.
final class CornerCardModel: ObservableObject {
    @Published var item: ShelfItem?
    @Published var image: NSImage?
    @Published var fileURL: URL?
    @Published var newCount = 0
    @Published var note: String?          // "Copied", "Saved to Pictures"
    @Published var thumbHidden = false    // while the fly-in is running
}

final class CornerCardController {
    var onClose: (() -> Void)?
    var onEdit: ((ShelfItem) -> Void)?
    private let store: ShelfStore
    private let model = CornerCardModel()
    private var panel: NSPanel?
    private var noteTimer: Timer?
    private var tuckTimer: Timer?
    /// The card tucks into the edge tab by itself this long after the last capture.
    static let tuckAfter: TimeInterval = 3

    static let cardWidth: CGFloat = 236
    static let margin: CGFloat = 20       // room for the shadow
    static let size = NSSize(width: cardWidth + margin * 2, height: 236 + margin * 2)

    init(store: ShelfStore) {
        self.store = store
        // Show the edited picture after the editor saves it.
        NotificationCenter.default.addObserver(forName: ShelfStore.changed, object: nil, queue: .main) { [weak self] _ in
            guard let self, let id = self.model.item?.id, let item = store.item(id) else { return }
            self.model.item = item
            self.model.image = store.image(for: item)
        }
    }

    var isShowing: Bool { panel?.isVisible == true }

    func show(_ item: ShelfItem, from rect: NSRect) {
        let wasShowing = isShowing
        model.item = item
        model.image = store.image(for: item)
        model.fileURL = store.url(for: item)
        model.newCount = wasShowing ? model.newCount + 1 : 1
        flashNote(Prefs.copyOnCapture ? "Copied" : nil)

        let p = panel ?? makePanel()
        panel = p
        let screen = NSScreen.screens.first { $0.frame.intersects(rect) } ?? Capture.screen
        let vf = screen.visibleFrame
        let origin = NSPoint(x: vf.maxX - Self.size.width - 24 + Self.margin,
                             y: vf.minY + 24 - Self.margin)
        closing = false
        p.setFrame(NSRect(origin: origin, size: Self.size), display: true)
        if !wasShowing { p.alphaValue = 0 }
        p.orderFrontRegardless()
        scheduleTuck(after: Self.tuckAfter)
        // The card's frame fades in while the screenshot flies into it.
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            p.animator().alphaValue = 1
        }

        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, let img = model.image {
            fly(img, from: rect, to: thumbRect(in: p.frame))
        }
    }

    private var closing = false

    /// Tucks toward the right edge, where the tab it turns into lives.
    /// Tucks the card away after a few seconds, but never while the pointer
    /// is on it or something is being dragged out of it.
    private func scheduleTuck(after delay: TimeInterval) {
        tuckTimer?.invalidate()
        tuckTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            guard let self, let p = self.panel, p.isVisible else { return }
            let busy = p.frame.contains(NSEvent.mouseLocation) || NSEvent.pressedMouseButtons != 0
            if busy { self.scheduleTuck(after: 1) } else { self.close() }
        }
    }

    func close() {
        tuckTimer?.invalidate()
        guard let p = panel, p.isVisible, !closing else { return }
        closing = true
        let to = Motion.reduce ? p.frame : p.frame.offsetBy(dx: 60, dy: 0)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Motion.reduce ? 0.12 : 0.22
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0, 1, 1)
            p.animator().setFrame(to, display: true)
            p.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, self.closing else { return }    // a new capture reopened it
            self.closing = false
            p.orderOut(nil)
            p.alphaValue = 1
            self.model.newCount = 0
            self.onClose?()
        })
    }

    // MARK: Fly-in

    private func thumbRect(in frame: NSRect) -> NSRect {
        let inset = Self.margin + 10
        return NSRect(x: frame.minX + inset, y: frame.maxY - inset - 135, width: 216, height: 135)
    }

    private func fly(_ image: NSImage, from: NSRect, to: NSRect) {
        model.thumbHidden = true
        let w = NSWindow(contentRect: from, styleMask: .borderless, backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.level = .floating
        w.hasShadow = true
        w.ignoresMouseEvents = true
        w.isReleasedWhenClosed = false
        let iv = NSImageView(frame: NSRect(origin: .zero, size: from.size))
        iv.image = image
        iv.imageScaling = .scaleAxesIndependently
        iv.autoresizingMask = [.width, .height]
        iv.wantsLayer = true
        iv.layer?.cornerRadius = 8
        iv.layer?.masksToBounds = true
        w.contentView = iv
        w.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.45
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)
            w.animator().setFrame(to, display: true)
        }, completionHandler: { [weak self] in
            self?.model.thumbHidden = false
            w.orderOut(nil)
        })
    }

    // MARK: Panel

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: Self.size),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = .floating
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.appearance = NSAppearance(named: .darkAqua)
        let view = CornerCardView(model: model,
                                  onCopy: { [weak self] in self?.copy() },
                                  onEdit: { [weak self] in
                                      guard let self, let item = self.model.item else { return }
                                      self.onEdit?(item)
                                  },
                                  onSave: { [weak self] in self?.save() },
                                  onClose: { [weak self] in self?.close() })
        p.contentView = NSHostingView(rootView: view)
        return p
    }

    private func copy() {
        guard let item = model.item else { return }
        store.copy(item)
        flashNote("Copied")
    }

    private func save() {
        guard let item = model.item else { return }
        flashNote(store.saveToPictures(item) == nil ? "Couldn't save" : "Saved")
    }

    private func flashNote(_ text: String?) {
        model.note = text
        noteTimer?.invalidate()
        guard text != nil else { return }
        noteTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { [weak self] _ in
            self?.model.note = nil
        }
    }
}

enum Capture {
    static var screen: NSScreen { CaptureController.screenUnderMouse() }
}

struct CornerCardView: View {
    @ObservedObject var model: CornerCardModel
    let onCopy: () -> Void
    let onEdit: () -> Void
    let onSave: () -> Void
    let onClose: () -> Void

    var body: some View {
        ZStack(alignment: .top) {
            if model.newCount > 2 {
                RoundedRectangle(cornerRadius: 12).fill(Color(white: 0.2))
                    .frame(width: 200, height: 40).offset(y: -14)
            }
            if model.newCount > 1 {
                RoundedRectangle(cornerRadius: 13).fill(Color(white: 0.25))
                    .frame(width: 218, height: 40).offset(y: -7)
            }
            VStack(spacing: 8) {
                thumb
                HStack(spacing: 2) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(model.item?.title ?? "")
                            .font(.system(size: 12.5, weight: .semibold))
                            .lineLimit(1)
                        Text(subtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(model.note == "Copied" ? Color.green : Color.secondary)
                            .monospacedDigit()
                    }
                    Spacer(minLength: 4)
                    IconButton(symbol: "pencil", help: "Edit", action: onEdit)
                    IconButton(symbol: "square.and.arrow.down", help: "Save as a file", action: onSave)
                    IconButton(symbol: "xmark", help: "Close", action: onClose)
                }
            }
            .padding(10)
            .frame(width: CornerCardController.cardWidth)
            .background(ZStack {
                BlurBackground(cornerRadius: 14)
                Color.black.opacity(0.32)   // darker glass so text reads over busy screens
            }.clipShape(RoundedRectangle(cornerRadius: 14)))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.45), radius: 16, y: 8)
        }
        .padding(CornerCardController.margin)
        .frame(width: CornerCardController.size.width, height: CornerCardController.size.height, alignment: .top)
    }

    private var subtitle: String {
        if let note = model.note { return note }
        if model.newCount > 1 { return "\(model.newCount) new" }
        guard let item = model.item else { return "" }
        return "\(item.kind) · \(item.date.formatted(date: .omitted, time: .shortened))"
    }

    private var thumb: some View {
        Group {
            if let img = model.image {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
            } else {
                Color.black
            }
        }
        .frame(width: 216, height: 135)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5))
        .opacity(model.thumbHidden ? 0 : 1)
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: onEdit)
        .onTapGesture(perform: onCopy)
        .onDrag { NSItemProvider(contentsOf: model.fileURL) ?? NSItemProvider() }
        .help("Click to copy again, double-click to edit. Drag it into any app.")
        .accessibilityLabel("Screenshot. Click to copy, drag to share.")
    }
}

struct IconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(hover ? 0.1 : 0)))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .onHover { hover = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Behind-window blur (macOS dark glass).
struct BlurBackground: NSViewRepresentable {
    var cornerRadius: CGFloat
    var corners: CACornerMask = [.layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMaxYCorner]

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        v.wantsLayer = true
        v.layer?.cornerRadius = cornerRadius
        v.layer?.maskedCorners = corners
        v.layer?.masksToBounds = true
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {
        // Corners can change (a stack card rounds its right side while it slides out).
        v.layer?.cornerRadius = cornerRadius
        v.layer?.maskedCorners = corners
    }
}
