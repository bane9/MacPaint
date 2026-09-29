import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Reusable hover button

struct HoverButton<Content: View>: View {
    var tip: String?
    var disabled = false
    var active = false
    var width: CGFloat?
    var height: CGFloat = 32
    var accentUnderline = false
    let action: () -> Void
    @ViewBuilder let content: () -> Content
    @State private var hovered = false

    var body: some View {
        Button(action: { if !disabled { action() } }) {
            content()
                .foregroundStyle(disabled ? Theme.textDisabled : Theme.textPrimary)
                .frame(width: width, height: height)
                .background(
                    RoundedRectangle(cornerRadius: Theme.radius)
                        .fill(active ? Color.white.opacity(0.09) : (hovered && !disabled ? Theme.bgControlHover : .clear))
                )
                .overlay(alignment: .bottom) {
                    if active && accentUnderline {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Theme.accent)
                            .frame(width: 16, height: 3)
                            .offset(y: -1)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(tip ?? "")
    }
}

// MARK: - Window helpers

struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
        override func mouseUp(with event: NSEvent) {
            if event.clickCount == 2 { window?.zoom(nil) }
        }
    }
    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ nsView: DragView, context: Context) {}
}

/// Configures the NSWindow for Win11-style chrome and close interception.
struct WindowConfigurator: NSViewRepresentable {
    let model: PaintModel
    let ui: UIState

    final class Coordinator: NSObject, NSWindowDelegate {
        let model: PaintModel
        let ui: UIState
        init(model: PaintModel, ui: UIState) {
            self.model = model
            self.ui = ui
        }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            if model.dirty {
                ui.confirmUnsaved(model: model) {
                    self.model.dirty = false
                    sender.close()
                }
                return false
            }
            return true
        }

        func windowWillClose(_ notification: Notification) {
            NSApp.terminate(nil)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(model: model, ui: ui) }

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async {
            guard let w = v.window else { return }
            w.title = "\(model.fileName) - Paint"
            w.styleMask.insert(.fullSizeContentView)
            w.titleVisibility = .hidden
            w.titlebarAppearsTransparent = true
            w.standardWindowButton(.closeButton)?.isHidden = true
            w.standardWindowButton(.miniaturizeButton)?.isHidden = true
            w.standardWindowButton(.zoomButton)?.isHidden = true
            w.isMovableByWindowBackground = false
            w.backgroundColor = NSColor(srgbRed: 0x20 / 255, green: 0x20 / 255, blue: 0x20 / 255, alpha: 1)
            w.delegate = context.coordinator
            w.minSize = NSSize(width: 900, height: 600)
            w.setContentSize(NSSize(width: 1280, height: 800))
            w.center()
            w.appearance = NSAppearance(named: .darkAqua)
        }
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.window?.title = "\(model.fileName) - Paint"
    }
}

// MARK: - Title bar

struct TitleBarView: View {
    @EnvironmentObject var model: PaintModel

    var body: some View {
        ZStack {
            WindowDragArea()
            HStack(spacing: 0) {
                HStack(spacing: 10) {
                    PaintAppIcon()
                        .frame(width: 16, height: 16)
                    Text("\(model.fileName) - Paint")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textPrimary)
                }
                .padding(.leading, 12)
                .allowsHitTesting(false)
                Spacer()
                WindowControls()
            }
        }
        .frame(height: 34)
        .background(Theme.bgWindow)
    }
}

struct PaintAppIcon: View {
    var body: some View {
        ZStack {
            // palette board
            PaletteBoardShape()
                .fill(Color(hex: 0xF2F2F2))
            Circle().fill(Color(hex: 0xE94F4F)).frame(width: 3.4, height: 3.4).offset(x: -3.4, y: -2.2)
            Circle().fill(Color(hex: 0xF7A827)).frame(width: 3.4, height: 3.4).offset(x: 0.4, y: -4.2)
            Circle().fill(Color(hex: 0x3FB950)).frame(width: 3.4, height: 3.4).offset(x: 4.0, y: -2.2)
            Circle().fill(Color(hex: 0x3F8DE0)).frame(width: 3.4, height: 3.4).offset(x: -3.8, y: 2.2)
        }
    }
}

struct PaletteBoardShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let w = rect.width, h = rect.height
        p.addEllipse(in: CGRect(x: 0, y: h * 0.05, width: w, height: h * 0.9))
        var bite = Path()
        bite.addEllipse(in: CGRect(x: w * 0.55, y: h * 0.42, width: w * 0.34, height: h * 0.3))
        return p.subtracting(bite)
    }
}

struct WindowControls: View {
    @State private var hoveredId: String?

    var body: some View {
        HStack(spacing: 0) {
            winButton("min", symbol: "minus") { NSApp.keyWindow?.miniaturize(nil) }
            winButton("max", symbol: "square") { NSApp.keyWindow?.zoom(nil) }
            winButton("close", symbol: "xmark") { NSApp.keyWindow?.performClose(nil) }
        }
    }

    private func winButton(_ id: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9.5, weight: .light))
                .foregroundStyle(hoveredId == id && id == "close" ? Color.white : Theme.textPrimary)
                .frame(width: 46, height: 34)
                .background(hoveredId == id ? (id == "close" ? Theme.closeRed : Color.white.opacity(0.06)) : .clear)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hoveredId = $0 ? id : (hoveredId == id ? nil : hoveredId) }
    }
}

// MARK: - File operations

@MainActor
enum FileOps {
    /// `onSaved` runs only after a successful save (used by the
    /// unsaved-changes flow so close/new/open wait for the save panel).
    static func save(model: PaintModel, ui: UIState, onSaved: (() -> Void)? = nil) {
        if let url = model.currentFileURL {
            if model.save(to: url) {
                onSaved?()
            } else {
                ui.toast("Couldn't save \(url.lastPathComponent) — choose a new location")
                saveAs(model: model, ui: ui, type: .png, ext: "png", onSaved: onSaved)
            }
        } else {
            saveAs(model: model, ui: ui, type: .png, ext: "png", onSaved: onSaved)
        }
    }

    static func saveAs(model: PaintModel, ui: UIState, type: UTType, ext: String, onSaved: (() -> Void)? = nil) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [type]
        panel.nameFieldStringValue = model.fileName + "." + ext
        panel.canCreateDirectories = true
        panel.begin { resp in
            guard resp == .OK, let url = panel.url else { return }
            Task { @MainActor in
                if model.save(to: url) {
                    onSaved?()
                } else {
                    ui.toast("Couldn't save \(url.lastPathComponent)")
                }
            }
        }
    }

    static func open(model: PaintModel, ui: UIState) {
        ui.confirmUnsaved(model: model) {
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.png, .jpeg, .bmp, .gif, .tiff, .heic, .webP, .image]
            panel.allowsMultipleSelection = false
            panel.begin { resp in
                guard resp == .OK, let url = panel.url else { return }
                Task { @MainActor in model.openImage(from: url) }
            }
        }
    }

    static func pasteFromFile(model: PaintModel) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.begin { resp in
            guard resp == .OK, let url = panel.url,
                  let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return }
            Task { @MainActor in model.pasteImage(img) }
        }
    }

    static func printDoc(model: PaintModel) {
        guard let img = model.compositeImage(overWhite: true) else { return }
        let nsImage = NSImage(cgImage: img, size: NSSize(width: model.docWidth, height: model.docHeight))
        let view = NSImageView(frame: NSRect(x: 0, y: 0, width: model.docWidth, height: model.docHeight))
        view.image = nsImage
        let op = NSPrintOperation(view: view)
        op.printInfo.horizontalPagination = .fit
        op.printInfo.verticalPagination = .fit
        op.run()
    }

    static func share(model: PaintModel) {
        guard let img = model.compositeImage(overWhite: true) else { return }
        let nsImage = NSImage(cgImage: img, size: NSSize(width: model.docWidth, height: model.docHeight))
        guard let contentView = NSApp.keyWindow?.contentView else { return }
        let picker = NSSharingServicePicker(items: [nsImage])
        picker.show(relativeTo: NSRect(x: contentView.bounds.midX, y: contentView.bounds.maxY - 80, width: 1, height: 1),
                    of: contentView, preferredEdge: .minY)
    }

    static func setAsDesktopBackground(model: PaintModel, ui: UIState) {
        guard let img = model.compositeImage(overWhite: true) else { return }
        let rep = NSBitmapImageRep(cgImage: img)
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PaintReplica", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("wallpaper-\(Int(Date().timeIntervalSince1970)).png")
        do {
            try png.write(to: url)
            if let screen = NSScreen.main {
                try NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: [:])
                ui.toast("Desktop background updated")
            }
        } catch {
            ui.toast("Couldn't set the desktop background")
        }
    }
}

// MARK: - Status bar

struct StatusBarView: View {
    @EnvironmentObject var model: PaintModel
    @EnvironmentObject var ui: UIState

    var body: some View {
        HStack(spacing: 0) {
            statusCell(icon: "cursorarrow", text: model.cursorText)
            statusCell(icon: "rectangle.dashed", text: model.selectionText)
            statusCell(icon: "aspectratio", text: model.sizeText)
            statusCell(icon: "doc", text: model.fileSizeText)
            Spacer()
            HStack(spacing: 2) {
                HoverButton(tip: "Fit to window", width: 30, height: 26, action: {
                    CanvasHolder.view?.fitToWindow()
                }) {
                    Image(systemName: "arrow.down.right.and.arrow.up.left").font(.system(size: 11))
                }
                HoverButton(tip: "Zoom level", height: 26, action: {
                    let items = PaintModel.zoomLevels.reversed().map { z in
                        MenuItem(
                            label: z * 100 == (z * 100).rounded() ? "\(Int(z * 100))%" : String(format: "%.1f%%", z * 100),
                            checked: abs(z - model.zoom) < 0.001,
                            action: { model.setZoom(z) }
                        )
                    }
                    ui.openMenu(Array(items), anchorId: "zoom-dd", alignRight: true)
                }) {
                    HStack(spacing: 5) {
                        Text(verbatim: model.zoomText)
                            .font(.system(size: 12))
                            .foregroundColor(.white)
                            .fixedSize()
                        Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
                    }
                    .padding(.horizontal, 6)
                }
                .reportFrame("zoom-dd")
                Rectangle().fill(Theme.strokeDivider).frame(width: 1, height: 18).padding(.horizontal, 6)
                HoverButton(tip: "Zoom out (Ctrl+-)", width: 30, height: 26, action: { model.zoomStep(-1) }) {
                    Image(systemName: "minus.magnifyingglass").font(.system(size: 12))
                }
                ZoomSlider()
                    .frame(width: 110)
                HoverButton(tip: "Zoom in (Ctrl++)", width: 30, height: 26, action: { model.zoomStep(1) }) {
                    Image(systemName: "plus.magnifyingglass").font(.system(size: 12))
                }
            }
            .padding(.trailing, 4)
        }
        .padding(.leading, 6)
        .frame(height: 34)
        .background(Theme.bgWindow)
    }

    private func statusCell(icon: String, text: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(Theme.textSecondary)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(minWidth: 110, maxHeight: 22)
        .overlay(alignment: .trailing) {
            Rectangle().fill(Theme.strokeDivider).frame(width: 1, height: 22)
        }
    }
}

struct ZoomSlider: View {
    @EnvironmentObject var model: PaintModel

    var body: some View {
        FluentSlider(
            value: Binding(
                get: { Double((model.zoom * 100).rounded()) },
                set: { model.setZoom(CGFloat($0) / 100) }
            ),
            range: Double(PaintModel.minZoom * 100)...Double(PaintModel.maxZoom * 100),
            step: 1
        )
    }
}

/// Win11-style slider (thin track, round accent thumb).
struct FluentSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 0
    var vertical = false
    var onEditingEnd: (() -> Void)? = nil

    var body: some View {
        GeometryReader { geo in
            let length = vertical ? geo.size.height : geo.size.width
            let frac = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
            let pos = CGFloat(vertical ? 1 - frac : frac) * max(1, length - 14) + 7
            ZStack(alignment: vertical ? .top : .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.35))
                    .frame(
                        width: vertical ? 4 : nil,
                        height: vertical ? nil : 4
                    )
                    .frame(maxWidth: vertical ? nil : .infinity, maxHeight: vertical ? .infinity : nil)
                Circle()
                    .fill(Theme.accent)
                    .frame(width: 8, height: 8)
                    .padding(3)
                    .background(Circle().fill(Color(hex: 0x454545)))
                    .overlay(Circle().stroke(Color.black.opacity(0.3), lineWidth: 1))
                    .offset(
                        x: vertical ? 0 : pos - 7,
                        y: vertical ? pos - 7 : 0
                    )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        let raw = vertical
                            ? 1 - (g.location.y - 7) / max(1, length - 14)
                            : (g.location.x - 7) / max(1, length - 14)
                        var v = range.lowerBound + Double(min(max(0, raw), 1)) * (range.upperBound - range.lowerBound)
                        if step > 0 { v = (v / step).rounded() * step }
                        value = min(max(range.lowerBound, v), range.upperBound)
                    }
                    .onEnded { _ in onEditingEnd?() }
            )
        }
        .frame(width: vertical ? 18 : nil, height: vertical ? nil : 18)
    }
}
