import AppKit
import SwiftUI
import ServiceManagement

/// The first-launch walkthrough: picture first, a few words, and each step
/// waits for you to actually do the thing (allow access, take a screenshot,
/// reach the edge, copy some text). Also in the menu under Welcome…
final class OnboardingController {
    static let textCopied = Notification.Name("SidesnapTextCopied")

    private var window: NSWindow?
    private var model: OnboardingModel?

    func show() {
        if window == nil {
            let m = OnboardingModel(store: AppHub.shared.store)
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 460),
                             styleMask: [.titled, .closable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isReleasedWhenClosed = false
            w.appearance = NSAppearance(named: .darkAqua)
            w.backgroundColor = NSColor(white: 0.118, alpha: 1)
            w.contentView = NSHostingView(rootView: OnboardingView(model: m))
            w.center()
            m.onFinish = { [weak self] in self?.finish() }
            window = w
            model = m
        }
        model?.go(.welcome)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func finish() {
        UserDefaults.standard.set(true, forKey: "didOnboard")
        model?.stopWatching()
        window?.close()
    }
}

final class OnboardingModel: ObservableObject {
    enum Step: Int, CaseIterable { case welcome, access, capture, shelf, edit, done }

    @Published var step: Step = .welcome
    @Published var allowed = Permission.hasAccess
    @Published var captured: NSImage?
    @Published var reachedEdge = false
    @Published var copiedText = false
    @Published var openAtLogin = SMAppService.mainApp.status == .enabled
    var onFinish: (() -> Void)?

    private let store: ShelfStore
    private var timer: Timer?
    private var observers: [Any] = []
    private var newestAtStart: UUID?

    init(store: ShelfStore) { self.store = store }

    /// Up to three recent screenshots for the pictures (empty on a brand-new Mac).
    var recent: [NSImage] { store.items.prefix(3).compactMap { store.thumbnail(for: $0) } }

    func go(_ s: Step) {
        stopWatching()
        step = s
        switch s {
        case .access:
            allowed = Permission.hasAccess
            poll { [weak self] in
                guard let self, !self.allowed, Permission.hasAccess else { return }
                self.allowed = true
                MenuIcon.shared.state = .ready
                // Show "Allowed" for a beat, then move on by itself.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { if self.step == .access { self.go(.capture) } }
            }
        case .capture:
            captured = nil
            newestAtStart = store.items.first?.id
            observers.append(NotificationCenter.default.addObserver(forName: ShelfStore.changed, object: nil, queue: .main) { [weak self] _ in
                guard let self, let first = self.store.items.first, first.id != self.newestAtStart else { return }
                self.captured = self.store.thumbnail(for: first)
            })
        case .shelf:
            reachedEdge = false
            poll { [weak self] in
                guard let self, !self.reachedEdge else { return }
                let p = NSEvent.mouseLocation
                if let screen = NSScreen.screens.first(where: { $0.frame.contains(p) }), p.x >= screen.frame.maxX - 3 {
                    self.reachedEdge = true
                }
            }
        case .edit:
            copiedText = false
            observers.append(NotificationCenter.default.addObserver(forName: OnboardingController.textCopied, object: nil, queue: .main) { [weak self] _ in
                self?.copiedText = true
            })
        case .welcome, .done:
            break
        }
    }

    func next() {
        if step == .access && !allowed { Permission.openSettings(); return }
        if step == .done { setLogin(openAtLogin); onFinish?(); return }
        go(Step(rawValue: step.rawValue + 1) ?? .done)
    }
    func back() { go(Step(rawValue: step.rawValue - 1) ?? .welcome) }
    func skip() { step == .welcome ? onFinish?() : go(Step(rawValue: step.rawValue + 1) ?? .done) }

    func stopWatching() {
        timer?.invalidate(); timer = nil
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
    }

    private func poll(_ tick: @escaping () -> Void) {
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in tick() }
    }

    private func setLogin(_ on: Bool) {
        if on { try? SMAppService.mainApp.register() } else { try? SMAppService.mainApp.unregister() }
    }
}

// MARK: - View

struct OnboardingView: View {
    @ObservedObject var model: OnboardingModel

    private var numbered: Int? {
        switch model.step {
        case .access: return 1
        case .capture: return 2
        case .shelf: return 3
        case .edit: return 4
        default: return nil
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                if let n = numbered {
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.1))
                        Capsule().fill(Color(white: 0.63)).frame(width: 120 * CGFloat(n) / 4)
                    }
                    .frame(width: 120, height: 3)
                    .animation(Motion.reduce ? nil : .spring(response: 0.4, dampingFraction: 1), value: n)
                }
            }
            .frame(height: 34)
            .padding(.horizontal, 14)

            VStack(alignment: .leading, spacing: 16) {
                stage
                    .frame(height: 250)
                    .frame(maxWidth: .infinity)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color(red: 0.086, green: 0.125, blue: 0.169)))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .id(model.step)
                    .transition(.opacity)
                words
            }
            .padding(.horizontal, 28)
            .padding(.top, 4)

            Spacer(minLength: 0)
            buttons
        }
        .frame(width: 640, height: 460)
        .background(Color(white: 0.118))
        .animation(Motion.reduce ? nil : .easeOut(duration: 0.2), value: model.step)
    }

    // MARK: Words

    private var titleAndCaption: (String, String) {
        let area = Prefs.combo(.area).display, full = Prefs.combo(.full).display, text = Prefs.combo(.text).display
        switch model.step {
        case .welcome: return ("Sidesnap", "Your screenshots, on a shelf at the edge.")
        case .access: return ("Turn on screen access", "One switch. Nothing leaves this Mac.")
        case .capture:
            return model.captured == nil
                ? ("Press \(area) and drag", "Space picks a window. \(full) takes the whole screen.")
                : ("Copied. Paste it anywhere.", "Or drag it from the corner.")
        case .shelf: return ("Hover the right edge", "Your screenshots wait there. Drag one out.")
        case .edit: return ("Mark it up, or grab the words", "Pencil to edit. \(text) copies text.")
        case .done: return ("You're set", "Find these again in Settings.")
        }
    }

    private var words: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(titleAndCaption.0).font(.system(size: 20, weight: .bold)).tracking(-0.4)
                Text(titleAndCaption.1).font(.system(size: 13)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            switch model.step {
            case .access: model.allowed ? AnyView(chip("Allowed", ok: true)) : AnyView(chip("Waiting", ok: false))
            case .capture: model.captured != nil ? AnyView(chip("Done", ok: true)) : AnyView(chip("Waiting", ok: false))
            case .shelf: model.reachedEdge ? AnyView(chip("Done", ok: true)) : AnyView(chip("Try it", ok: false))
            case .edit: model.copiedText ? AnyView(chip("Done", ok: true)) : AnyView(chip("Try it", ok: false))
            case .done:
                AnyView(Toggle("Open at login", isOn: $model.openAtLogin).toggleStyle(.checkbox)
                    .font(.system(size: 12.5)).foregroundStyle(.secondary))
            case .welcome: AnyView(EmptyView())
            }
        }
    }

    private func chip(_ label: String, ok: Bool) -> some View {
        HStack(spacing: 6) {
            if ok {
                Image(systemName: "checkmark").font(.system(size: 10, weight: .bold))
            } else {
                ProgressView().controlSize(.mini)
            }
            Text(label).font(.system(size: 12))
        }
        .foregroundStyle(ok ? Color(red: 0.36, green: 0.88, blue: 0.54) : Color.secondary)
        .padding(.horizontal, 10).frame(height: 26)
        .background(Capsule().fill(Color.white.opacity(0.07)))
    }

    // MARK: Buttons

    private var buttons: some View {
        HStack(spacing: 8) {
            if model.step != .done {
                Button(model.step == .welcome ? "Skip" : "Skip step") { model.skip() }
                    .buttonStyle(.plain).foregroundStyle(.secondary).padding(.horizontal, 6)
            }
            Spacer()
            if numbered != nil && model.step != .access {
                Button("Back") { model.back() }.buttonStyle(OnbButton(primary: false))
            }
            Button(primaryLabel) { model.next() }
                .buttonStyle(OnbButton(primary: true))
                .keyboardShortcut(.defaultAction)
                .opacity(model.step == .capture && model.captured == nil ? 0.45 : 1)
        }
        .padding(EdgeInsets(top: 14, leading: 20, bottom: 18, trailing: 20))
    }

    private var primaryLabel: String {
        switch model.step {
        case .welcome: return "Get Started"
        case .access: return model.allowed ? "Continue" : "Open Settings"
        case .done: return "Start Using Sidesnap"
        default: return "Continue"
        }
    }

    // MARK: Pictures

    @ViewBuilder private var stage: some View {
        switch model.step {
        case .welcome: welcomeArt
        case .access: accessArt
        case .capture: model.captured == nil ? AnyView(selectArt) : AnyView(copiedArt)
        case .shelf: shelfArt
        case .edit: editArt
        case .done: doneArt
        }
    }

    private func thumb(_ i: Int, w: CGFloat) -> some View {
        let imgs = model.recent
        return Group {
            if i < imgs.count {
                Image(nsImage: imgs[i]).resizable().aspectRatio(contentMode: .fill)
            } else {
                LinearGradient(colors: [Color(white: 0.3), Color(white: 0.2)], startPoint: .top, endPoint: .bottom)
            }
        }
        .frame(width: w, height: w * 0.625)
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }

    private func tab(_ i: Int, w: CGFloat) -> some View {
        thumb(i, w: w)
            .padding(EdgeInsets(top: 5, leading: 5, bottom: 5, trailing: 6))
            .background(UnevenRoundedRectangle(topLeadingRadius: 8, bottomLeadingRadius: 8).fill(Color(white: 0.18)))
            .overlay(UnevenRoundedRectangle(topLeadingRadius: 8, bottomLeadingRadius: 8).strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.45), radius: 10, y: 6)
    }

    private var welcomeArt: some View {
        ZStack {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 128, height: 128)
                .shadow(color: .black.opacity(0.4), radius: 16, y: 8)
            VStack(alignment: .trailing, spacing: 10) {
                tab(0, w: 70); tab(1, w: 70); tab(2, w: 70)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
        }
    }

    private var accessArt: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Screen Recording").font(.system(size: 12)).foregroundStyle(.secondary)
                .padding(.horizontal, 16).padding(.vertical, 10)
            Divider().opacity(0.4)
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 34, height: 34)
                Text("Sidesnap").font(.system(size: 15, weight: .semibold))
                Spacer()
                ZStack(alignment: model.allowed ? .trailing : .leading) {
                    Capsule().fill(model.allowed ? Color.accentColor : Color.white.opacity(0.2))
                    Circle().fill(.white).padding(3).shadow(radius: 1)
                }
                .frame(width: 46, height: 28)
                .animation(Motion.reduce ? nil : .spring(response: 0.3, dampingFraction: 1), value: model.allowed)
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
        }
        .frame(width: 380)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(white: 0.14)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.white.opacity(0.1), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.45), radius: 16, y: 8)
    }

    private var selectArt: some View {
        ZStack(alignment: .bottomLeading) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(Color(white: 0.16)).frame(width: 360, height: 210)
                Color.black.opacity(0.35)
                Rectangle().strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])).foregroundStyle(.white)
                    .frame(width: 200, height: 110).offset(x: 40, y: -10)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Keycaps(combo: Prefs.combo(.area), size: 46).padding(18)
        }
    }

    private var copiedArt: some View {
        HStack(spacing: 28) {
            Keycaps(text: "⌘V", size: 46)
            VStack(alignment: .leading, spacing: 8) {
                if let img = model.captured {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                        .frame(width: 216, height: 135).clipShape(RoundedRectangle(cornerRadius: 8))
                }
                Label("Copied", systemImage: "checkmark").font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color(red: 0.36, green: 0.88, blue: 0.54))
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color(white: 0.17)))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.45), radius: 14, y: 8)
        }
    }

    private var shelfArt: some View {
        ZStack {
            HStack {
                RoundedRectangle(cornerRadius: 8).fill(Color(white: 0.14)).frame(width: 220, height: 170)
                    .overlay(alignment: .bottomLeading) {
                        thumb(1, w: 112).rotationEffect(.degrees(-3))
                            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.accentColor, lineWidth: 1.5))
                            .padding(14)
                    }
                Spacer()
            }
            .padding(.leading, 30)
            VStack(alignment: .trailing, spacing: 12) {
                tab(0, w: 112)
                tab(1, w: 112).offset(x: -14).scaleEffect(1.04, anchor: .trailing)
                tab(2, w: 112)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
        }
    }

    private var editArt: some View {
        HStack(spacing: 30) {
            ZStack {
                thumb(0, w: 250)
                RoundedRectangle(cornerRadius: 4).strokeBorder(Color.red, lineWidth: 3).frame(width: 80, height: 44).offset(x: -40, y: 10)
                Image(systemName: "arrow.up.left").font(.system(size: 30, weight: .bold)).foregroundStyle(.red)
                    .offset(x: 30, y: 30)
            }
            VStack(alignment: .leading, spacing: 9) {
                Capsule().fill(Color.white.opacity(0.18)).frame(width: 150, height: 9)
                VStack(alignment: .leading, spacing: 7) {
                    Capsule().fill(Color.accentColor.opacity(0.55)).frame(width: 170, height: 9)
                    Capsule().fill(Color.accentColor.opacity(0.55)).frame(width: 130, height: 9)
                }
                .padding(7)
                .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])).foregroundStyle(.white))
                Capsule().fill(Color.white.opacity(0.18)).frame(width: 110, height: 9)
                Keycaps(combo: Prefs.combo(.text), size: 30).padding(.top, 12)
            }
        }
    }

    private var doneArt: some View {
        HStack(spacing: 28) {
            ForEach([(Prefs.combo(.area), "Area"), (Prefs.combo(.full), "Screen"), (Prefs.combo(.text), "Text")], id: \.1) { combo, label in
                VStack(spacing: 12) {
                    Keycaps(combo: combo, size: 46)
                    Text(label).font(.system(size: 13)).foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// Big keyboard keys, e.g. ⌥ ⇧ S.
struct Keycaps: View {
    let keys: [String]
    let size: CGFloat

    init(combo: KeyCombo, size: CGFloat) {
        keys = combo.display.map { String($0) }
        self.size = size
    }
    init(text: String, size: CGFloat) {
        keys = text.map { String($0) }
        self.size = size
    }

    var body: some View {
        HStack(spacing: size * 0.12) {
            ForEach(Array(keys.enumerated()), id: \.offset) { _, k in
                Text(k)
                    .font(.system(size: size * 0.43, weight: .semibold))
                    .frame(minWidth: size, minHeight: size)
                    .padding(.horizontal, k.count > 1 ? size * 0.2 : 0)
                    .background(RoundedRectangle(cornerRadius: size * 0.22).fill(Color(white: 0.17)))
                    .overlay(RoundedRectangle(cornerRadius: size * 0.22).strokeBorder(Color.white.opacity(0.16), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.5), radius: 0, y: 2)
            }
        }
    }
}

struct OnbButton: ButtonStyle {
    let primary: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: primary ? .semibold : .regular))
            .padding(.horizontal, primary ? 18 : 14).frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 8).fill(primary ? Color.accentColor : Color.white.opacity(0.1)))
            .foregroundStyle(.white)
            .scaleEffect(configuration.isPressed && !Motion.reduce ? 0.97 : 1)
    }
}
