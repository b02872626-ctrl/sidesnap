import AppKit
import SwiftUI
import Vision

/// Reads the words (or a QR / barcode) in a picture, on this Mac only.
enum TextReader {
    enum Found { case text(String), qr(String), nothing }

    static func read(_ cg: CGImage, done: @escaping (Found) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let barcodes = VNDetectBarcodesRequest()
            let words = VNRecognizeTextRequest()
            words.recognitionLevel = .accurate
            words.usesLanguageCorrection = true
            try? VNImageRequestHandler(cgImage: cg).perform([barcodes, words])

            // A QR code wins: if you selected one, you want its link.
            let code = (barcodes.results ?? []).compactMap(\.payloadStringValue).first
            // Rows top to bottom; pieces on the same row joined with a space.
            let obs = (words.results ?? []).sorted { $0.boundingBox.midY > $1.boundingBox.midY }
            var rows: [[VNRecognizedTextObservation]] = []
            for o in obs {
                if let last = rows.last?.first,
                   abs(last.boundingBox.midY - o.boundingBox.midY) < min(last.boundingBox.height, o.boundingBox.height) * 0.5 {
                    rows[rows.count - 1].append(o)
                } else {
                    rows.append([o])
                }
            }
            let lines = rows.map { row in
                row.sorted { $0.boundingBox.minX < $1.boundingBox.minX }
                    .compactMap { $0.topCandidates(1).first?.string }
                    .joined(separator: " ")
            }
            let text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)

            let found: Found = code.map { .qr($0) } ?? (text.isEmpty ? .nothing : .text(text))
            DispatchQueue.main.async { done(found) }
        }
    }

    /// The text of a shelf screenshot, read fresh so line breaks are kept
    /// (the stored search text is one long line).
    static func text(of item: ShelfItem, store: ShelfStore, done: @escaping (String?) -> Void) {
        guard let cg = store.image(for: item)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            done(nil); return
        }
        read(cg) { found in
            switch found {
            case let .text(t): done(t)
            case let .qr(q): done(q)
            case .nothing: done(nil)
            }
        }
    }
}

/// A small dark note that says what was copied, then fades away.
enum TextHUD {
    private static var panel: NSPanel?
    private static var hideWork: DispatchWorkItem?

    static func show(_ title: String, detail: String?, near rect: NSRect) {
        let p = panel ?? make()
        panel = p
        p.contentView = NSHostingView(rootView: HUDView(title: title, detail: detail))
        let size = p.contentView!.fittingSize
        let screen = NSScreen.screens.first { $0.frame.intersects(rect) } ?? NSScreen.main ?? NSScreen.screens[0]
        var origin = NSPoint(x: rect.midX - size.width / 2, y: rect.minY - size.height - 12)
        if origin.y < screen.visibleFrame.minY + 8 { origin.y = rect.maxY + 12 }
        origin.x = min(max(origin.x, screen.visibleFrame.minX + 8), screen.visibleFrame.maxX - size.width - 8)
        p.setFrame(NSRect(origin: origin, size: size), display: true)
        p.alphaValue = 0
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; p.animator().alphaValue = 1 }

        hideWork?.cancel()
        let work = DispatchWorkItem {
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.25; p.animator().alphaValue = 0 },
                                                 completionHandler: { p.orderOut(nil) })
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2, execute: work)
    }

    private static func make() -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = .statusBar
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.appearance = NSAppearance(named: .darkAqua)
        return p
    }
}

private struct HUDView: View {
    let title: String
    let detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 13, weight: .semibold))
            if let detail, !detail.isEmpty {
                Text(detail).font(.system(size: 11.5)).foregroundStyle(.secondary)
                    .lineLimit(2).frame(maxWidth: 320, alignment: .leading)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(ZStack { BlurBackground(cornerRadius: 12); Color.black.opacity(0.3) }
            .clipShape(RoundedRectangle(cornerRadius: 12)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))
        .padding(16)
        .shadow(color: .black.opacity(0.4), radius: 12, y: 6)
    }
}
