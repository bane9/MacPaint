import SwiftUI
import AppKit
import UniformTypeIdentifiers

@main
struct PaintApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var model = PaintModel()
    @StateObject private var ui = UIState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .environmentObject(ui)
                .preferredColorScheme(.dark)
                .onAppear {
                    KeyboardHandler.install(model: model, ui: ui)
                    DemoMode.run(model: model, ui: ui)
                    AppDelegate.openURLHandler = { url in
                        guard model.canOpenImage(from: url) else { return }
                        ui.confirmUnsaved(model: model) {
                            model.openImage(from: url)
                        }
                    }
                    AppDelegate.flushPendingOpenURLs()
                    let m = model, u = ui
                    AppDelegate.terminateGuard = {
                        guard m.dirty else { return true }
                        u.confirmUnsaved(model: m) {
                            m.dirty = false
                            NSApp.terminate(nil)
                        }
                        return false
                    }
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .commands {
            PaintCommands(model: model, ui: ui)
        }
    }
}

/// Native macOS menu bar (replaces the in-window File/Edit/View row).
/// The standard Edit Cut/Copy/Paste/Select All items are kept as-is: they
/// route through the responder chain to text fields or to the canvas view.
struct PaintCommands: Commands {
    @ObservedObject var model: PaintModel
    @ObservedObject var ui: UIState

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About Paint") { ui.dialog = .about }
        }

        CommandGroup(replacing: .newItem) {
            Button("New") { ui.confirmUnsaved(model: model) { model.newUntitled() } }
                .keyboardShortcut("n")
            Button("Open…") { FileOps.open(model: model, ui: ui) }
                .keyboardShortcut("o")
            Menu("Open Recent") {
                let recents = model.recentFiles()
                if recents.isEmpty {
                    Button("No Recent Files") {}.disabled(true)
                } else {
                    ForEach(recents, id: \.self) { url in
                        Button(url.lastPathComponent) {
                            ui.confirmUnsaved(model: model) { model.openImage(from: url) }
                        }
                    }
                }
            }
        }

        CommandGroup(replacing: .saveItem) {
            Button("Save") { FileOps.save(model: model, ui: ui) }
                .keyboardShortcut("s")
            Menu("Save As") {
                Button("PNG Picture") { FileOps.saveAs(model: model, ui: ui, type: .png, ext: "png") }
                Button("JPEG Picture") { FileOps.saveAs(model: model, ui: ui, type: .jpeg, ext: "jpg") }
                Button("BMP Picture") { FileOps.saveAs(model: model, ui: ui, type: .bmp, ext: "bmp") }
                Button("GIF Picture") { FileOps.saveAs(model: model, ui: ui, type: .gif, ext: "gif") }
            }
            Divider()
            Button("Share…") { FileOps.share(model: model) }
            Menu("Set as Desktop Background") {
                Button("Fill") { FileOps.setAsDesktopBackground(model: model, ui: ui) }
                Button("Tile") { FileOps.setAsDesktopBackground(model: model, ui: ui) }
                Button("Center") { FileOps.setAsDesktopBackground(model: model, ui: ui) }
            }
            Divider()
            Button("Resize and Skew…") { ui.dialog = .resizeSkew }
            Button("Image Properties…") { ui.dialog = .imageProperties }
                .keyboardShortcut("e")
        }

        CommandGroup(replacing: .printItem) {
            Button("Print…") { FileOps.printDoc(model: model) }
                .keyboardShortcut("p")
        }

        CommandGroup(replacing: .undoRedo) {
            // route to the focused text editor's undo stack while typing,
            // otherwise to the document history
            Button("Undo") {
                if let tv = NSApp.keyWindow?.firstResponder as? NSTextView {
                    tv.undoManager?.undo()
                } else {
                    model.undo()
                }
            }
            .keyboardShortcut("z")
            Button("Redo") {
                if let tv = NSApp.keyWindow?.firstResponder as? NSTextView {
                    tv.undoManager?.redo()
                } else {
                    model.redo()
                }
            }
            .keyboardShortcut("z", modifiers: [.command, .shift])
        }

        CommandGroup(before: .toolbar) {
            Button("Zoom In") { model.zoomStep(1) }
                .keyboardShortcut("+")
            Button("Zoom Out") { model.zoomStep(-1) }
                .keyboardShortcut("-")
            Button("Zoom to 100%") { model.setZoom(1) }
                .keyboardShortcut("0")
            Divider()
            Toggle("Rulers", isOn: Binding(
                get: { model.rulersOn },
                set: { model.rulersOn = $0 }
            ))
            .keyboardShortcut("r")
            Toggle("Gridlines", isOn: Binding(
                get: { model.gridOn },
                set: { model.gridOn = $0; model.repaint() }
            ))
            .keyboardShortcut("g")
            Divider()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Returns true when it is safe to terminate; otherwise it shows the
    /// unsaved-changes dialog itself. Installed from ContentView.
    static var terminateGuard: (() -> Bool)?
    static var openURLHandler: ((URL) -> Void)?
    private static var pendingOpenURLs: [URL] = []

    static func requestOpenURL(_ url: URL) {
        if let handler = openURLHandler {
            handler(url)
        } else {
            pendingOpenURLs.append(url)
        }
    }

    static func flushPendingOpenURLs() {
        guard let handler = openURLHandler else { return }
        let queued = pendingOpenURLs
        pendingOpenURLs.removeAll()
        for url in queued {
            handler(url)
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if let allow = AppDelegate.terminateGuard, !allow() {
            return .terminateCancel
        }
        return .terminateNow
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        // Debug hook: `PAINT_SCREENSHOT=out.png Paint` renders the window into
        // a PNG (no screen-recording permission needed) and exits.
        let env = ProcessInfo.processInfo.environment
        if let path = env["PAINT_SCREENSHOT"] {
            let delay = Double(env["PAINT_SCREENSHOT_DELAY"] ?? "") ?? 1.5
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                if ProcessInfo.processInfo.environment["PAINT_DUMP_MENU"] != nil, let main = NSApp.mainMenu {
                    var dump = ""
                    for item in main.items {
                        dump += "[\(item.title)] "
                        if let sub = item.submenu {
                            dump += sub.items.map { $0.isSeparatorItem ? "---" : $0.title }.joined(separator: " | ")
                        }
                        dump += "\n"
                    }
                    FileHandle.standardError.write(dump.data(using: .utf8)!)
                }
                FileHandle.standardError.write("windows: \(NSApp.windows.map { "\($0.title) \($0.frame)" })\n".data(using: .utf8)!)
                guard let w = NSApp.windows.first(where: { $0.contentView != nil && $0.frame.width > 200 }),
                      let v = w.contentView,
                      let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else {
                    FileHandle.standardError.write("screenshot: no usable window\n".data(using: .utf8)!)
                    exit(1)
                }
                v.cacheDisplay(in: v.bounds, to: rep)
                do {
                    try rep.representation(using: .png, properties: [:])?
                        .write(to: URL(fileURLWithPath: path))
                } catch {
                    FileHandle.standardError.write("screenshot write failed: \(error)\n".data(using: .utf8)!)
                    exit(1)
                }
                exit(0)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        let url = URL(fileURLWithPath: filename)
        AppDelegate.requestOpenURL(url)
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            AppDelegate.requestOpenURL(url)
        }
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        for file in filenames {
            AppDelegate.requestOpenURL(URL(fileURLWithPath: file))
        }
    }
}

// MARK: - Content view

struct ContentView: View {
    @EnvironmentObject var model: PaintModel
    @EnvironmentObject var ui: UIState

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                TitleBarView()
                RibbonView()
                ZStack {
                    CanvasArea(model: model)
                        .overlay(alignment: .leading) {
                            SizePanel()
                        }
                        .overlay(alignment: .trailing) {
                            if ui.layersPanelOpen {
                                LayersPanel()
                            } else if ui.stickersPanelOpen {
                                StickersPanel()
                            }
                        }
                        .overlay(alignment: .top) {
                            if model.textEditing {
                                TextOptionsBar()
                                    .padding(.top, 10)
                            }
                        }
                }
                StatusBarView()
            }
            .background(Theme.bgWindow)

            PopupLayer()
            DialogLayer()
            ToastLayer()
        }
        .background(WindowConfigurator(model: model, ui: ui))
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: nil) { providers in
            let accepted = providers.contains { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
            for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    let data = item as? Data
                    let str = item as? String
                    let url: URL?
                    if let data, let s = String(data: data, encoding: .utf8) {
                        url = URL(string: s)
                    } else if let str {
                        url = URL(string: str)
                    } else {
                        url = item as? URL
                    }
                    guard let fileURL = url?.standardizedFileURL else { return }
                    Task { @MainActor in
                        AppDelegate.requestOpenURL(fileURL)
                    }
                }
            }
            return accepted
        }
        .environment(\.colorScheme, .dark)
    }
}

// MARK: - Demo hook (visual verification without UI event injection)

@MainActor
enum DemoMode {
    static func run(model: PaintModel, ui: UIState) {
        guard let demo = ProcessInfo.processInfo.environment["PAINT_DEMO"] else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            switch demo {
            case "draw":
                drawSample(model)
            case "layers":
                drawSample(model)
                model.addLayer()
                ui.layersPanelOpen = true
            case "editcolors":
                ui.dialog = .editColors
            case "resize":
                ui.dialog = .resizeSkew
            case "zoomed":
                drawSample(model)
                model.setZoom(3)
                model.gridOn = true
                model.repaint()
            case "io":
                // headless save/open round-trip across all four formats
                drawSample(model)
                model.dropSelection()
                let dir = FileManager.default.temporaryDirectory.appendingPathComponent("paint-io-test")
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                var report: [String] = []
                for ext in ["png", "jpg", "bmp", "gif"] {
                    let url = dir.appendingPathComponent("roundtrip.\(ext)")
                    let ok = model.save(to: url)
                    let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
                    report.append("\(ext): save=\(ok) bytes=\(size)")
                }
                let pngURL = dir.appendingPathComponent("roundtrip.png")
                model.openImage(from: pngURL)
                report.append("reopened: \(model.docWidth)x\(model.docHeight) name=\(model.fileName)")
                FileHandle.standardError.write((report.joined(separator: "\n") + "\n").data(using: .utf8)!)
            case "mouse":
                runMouseScript(model)
            case "selundo":
                // undo with a floating selection must cancel the lift, not
                // skip back past the last committed step
                var log: [String] = []
                BrushEngine.lineSegment(model.activeLayer.ctx, CGPoint(x: 100, y: 100), CGPoint(x: 300, y: 100), width: 6, color: .black)
                model.commit() // history: [blank, line]
                let lineVisible: @MainActor () -> Bool = {
                    (model.pickColor(at: CGPoint(x: 200, y: 100)) ?? .white) == RGB.black
                }
                log.append("afterDraw lineVisible=\(lineVisible())")
                model.setTool(.select)
                model.setSelection(Selection(rect: CGRect(x: 80, y: 80, width: 250, height: 50), floating: nil, freePath: nil))
                model.liftSelection()
                if var sel = model.selection { sel.rect.origin = CGPoint(x: 300, y: 300); model.selection = sel }
                model.repaint()
                log.append("afterMove floating=\(model.selection?.floating != nil) lineAtOrigVisible=\(lineVisible())")
                model.undo() // should cancel the lift -> line back, selection gone
                log.append("afterUndo1 sel=\(model.selection != nil) lineVisible=\(lineVisible()) canUndo=\(model.canUndo)")
                model.undo() // now undo the line itself
                log.append("afterUndo2 lineVisible=\(lineVisible())")
                FileHandle.standardError.write((log.joined(separator: "\n") + "\n").data(using: .utf8)!)
            case "transforms":
                // rotate/flip/resize/skew/crop + undo chain sanity
                drawSample(model)
                model.dropSelection()
                var log: [String] = []
                model.rotate(90)
                log.append("rot90 -> \(model.docWidth)x\(model.docHeight)")
                model.rotate(-90)
                log.append("rot-90 -> \(model.docWidth)x\(model.docHeight)")
                model.flip(horizontal: true)
                model.flip(horizontal: false)
                model.resizeCanvas(width: 400, height: 256, stretch: true)
                log.append("stretch -> \(model.docWidth)x\(model.docHeight)")
                model.skew(hDeg: 20, vDeg: 0)
                log.append("skew -> \(model.docWidth)x\(model.docHeight)")
                model.setSelection(Selection(rect: CGRect(x: 20, y: 20, width: 200, height: 150), floating: nil, freePath: nil))
                model.cropToSelection()
                log.append("crop -> \(model.docWidth)x\(model.docHeight)")
                var undos = 0
                while model.canUndo { model.undo(); undos += 1 }
                log.append("undosToStart=\(undos) size=\(model.docWidth)x\(model.docHeight)")
                while model.canRedo { model.redo() }
                log.append("afterRedoAll=\(model.docWidth)x\(model.docHeight)")
                FileHandle.standardError.write((log.joined(separator: "\n") + "\n").data(using: .utf8)!)
            default:
                break
            }
        }
    }

    /// Drives the real NSEvent path (mouseDown/Dragged/Up on the canvas view).
    static func runMouseScript(_ model: PaintModel) {
        guard let doc = CanvasHolder.view, let win = doc.window else { return }
        func ev(_ type: NSEvent.EventType, _ docPt: CGPoint) -> NSEvent {
            let vp = doc.viewPoint(fromDoc: docPt)
            let wp = doc.convert(vp, to: nil)
            return NSEvent.mouseEvent(
                with: type, location: wp, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: win.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 1
            )!
        }
        func drag(from a: CGPoint, to b: CGPoint, steps: Int = 20) {
            doc.mouseDown(with: ev(.leftMouseDown, a))
            for i in 1...steps {
                let t = CGFloat(i) / CGFloat(steps)
                doc.mouseDragged(with: ev(.leftMouseDragged, CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)))
            }
            doc.mouseUp(with: ev(.leftMouseUp, b))
        }

        // brush stroke through the event pipeline
        model.setTool(.brush)
        model.brushType = .brush
        doc.mouseDown(with: ev(.leftMouseDown, CGPoint(x: 90, y: 110)))
        for i in 1...40 {
            let x = 90.0 + Double(i) * 11
            doc.mouseDragged(with: ev(.leftMouseDragged, CGPoint(x: x, y: 110 + sin(Double(i) / 4) * 45)))
        }
        doc.mouseUp(with: ev(.leftMouseUp, CGPoint(x: 530, y: 110)))

        // filled hexagon via shape drag
        model.setColor(well: 1, RGB(hex: "#3F48CC"))
        model.fillStyle = .solid
        model.shapeId = "hexagon"
        model.setTool(.shape)
        drag(from: CGPoint(x: 140, y: 240), to: CGPoint(x: 340, y: 400))

        // line tool
        model.shapeId = "line"
        model.setTool(.shape)
        drag(from: CGPoint(x: 420, y: 420), to: CGPoint(x: 740, y: 260))

        // rectangle selection + move through the event pipeline
        model.setTool(.select)
        drag(from: CGPoint(x: 120, y: 220), to: CGPoint(x: 360, y: 420), steps: 8)
        drag(from: CGPoint(x: 240, y: 320), to: CGPoint(x: 520, y: 200), steps: 8)

        // eraser swipe
        model.setTool(.eraser)
        drag(from: CGPoint(x: 300, y: 90), to: CGPoint(x: 300, y: 160), steps: 8)

        model.repaint()
    }

    static func drawSample(_ model: PaintModel) {
        let layer = model.activeLayer
        let ctx = layer.ctx

        // brush stroke (sine wave)
        var prev = CGPoint(x: 80, y: 120)
        for i in 1...60 {
            let t = CGFloat(i) / 60
            let p = CGPoint(x: 80 + t * 300, y: 120 + sin(t * .pi * 2) * 60)
            BrushEngine.stampSegment(ctx: ctx, from: prev, to: p, tool: .brush, brush: .brush, size: 8, color: RGB(hex: "#ED1C24"))
            prev = p
        }

        // star shape, filled + outlined
        let star = ShapeLibrary.byId("star-5")
        let path = star.path(in: CGRect(x: 460, y: 60, width: 150, height: 150))
        ctx.setFillColor(RGB(hex: "#FFC90E").cgColor)
        ctx.addPath(path)
        ctx.fillPath()
        ctx.setStrokeColor(RGB.black.cgColor)
        ctx.setLineWidth(3)
        ctx.addPath(path)
        ctx.strokePath()

        // outlined ellipse, then flood-filled interior
        ctx.setStrokeColor(RGB(hex: "#22B14C").cgColor)
        ctx.setLineWidth(4)
        ctx.strokeEllipse(in: CGRect(x: 120, y: 260, width: 180, height: 140))
        model.commit()
        model.floodFill(at: CGPoint(x: 210, y: 330), color: RGB(hex: "#99D9EA"))

        // rasterized text
        model.textStyle.size = 28
        model.textStyle.bold = true
        model.rasterizeText("Hello from Swift Paint", at: CGPoint(x: 380, y: 320), boxWidth: 380)

        // floating selection (lifted + moved)
        model.setTool(.select)
        model.setSelection(Selection(rect: CGRect(x: 460, y: 60, width: 150, height: 150), floating: nil, freePath: nil))
        model.liftSelection()
        if var sel = model.selection {
            sel.rect.origin = CGPoint(x: 590, y: 300)
            model.selection = sel
        }
        model.repaint()
    }
}

// MARK: - Keyboard shortcuts (Windows Paint bindings; Cmd and Ctrl both work)

@MainActor
enum KeyboardHandler {
    private static var monitor: Any?

    static func install(model: PaintModel, ui: UIState) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            handle(e, model: model, ui: ui) ? nil : e
        }
    }

    private static func handle(_ e: NSEvent, model: PaintModel, ui: UIState) -> Bool {
        let responder = NSApp.keyWindow?.firstResponder
        let editingText = responder is NSTextView || responder is NSText

        // Escape always works
        if e.keyCode == 53 {
            if ui.activeMenu != nil { ui.closeMenus(); return true }
            if ui.dialog != nil { ui.dialog = nil; ui.pendingUnsavedAction = nil; return true }
            if let canvas = CanvasHolder.view {
                if canvas.hasActiveText() { canvas.cancelActiveText(); return true }
                canvas.cancelTransient()
            }
            if model.selection != nil { model.dropSelection(); return true }
            return false
        }

        if editingText { return false }

        // while a modal dialog is up, don't let shortcuts mutate the document
        if ui.dialog != nil { return false }

        let mods = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let cmd = mods.contains(.command) || mods.contains(.control)
        let shift = mods.contains(.shift)
        let key = e.charactersIgnoringModifiers?.lowercased() ?? ""

        if cmd {
            switch key {
            case "z": shift ? model.redo() : model.undo(); return true
            case "y": model.redo(); return true
            case "s":
                if shift { FileOps.saveAs(model: model, ui: ui, type: .png, ext: "png") }
                else { FileOps.save(model: model, ui: ui) }
                return true
            case "n": ui.confirmUnsaved(model: model) { model.newUntitled() }; return true
            case "o": FileOps.open(model: model, ui: ui); return true
            case "a": model.selectAll(); return true
            case "c": model.copySelection(); return true
            case "x": model.cutSelection(); return true
            case "v": model.paste(); return true
            case "e": ui.dialog = .imageProperties; return true
            case "w": ui.dialog = .resizeSkew; return true
            case "r": model.rulersOn.toggle(); return true
            case "g": model.gridOn.toggle(); model.repaint(); return true
            case "p": FileOps.printDoc(model: model); return true
            case "+", "=": model.zoomStep(1); return true
            case "-": model.zoomStep(-1); return true
            case "0": model.setZoom(1); return true
            case "q": NSApp.terminate(nil); return true
            default: return false
            }
        }

        // Delete / Backspace
        if e.keyCode == 51 || e.keyCode == 117 {
            if model.selection != nil {
                model.deleteSelection()
                return true
            }
            return false
        }

        // Arrow keys nudge the selection
        if model.selection != nil {
            let step: CGFloat = shift ? 8 : 1
            switch e.keyCode {
            case 123: CanvasHolder.view?.nudgeSelection(dx: -step, dy: 0); return true
            case 124: CanvasHolder.view?.nudgeSelection(dx: step, dy: 0); return true
            case 125: CanvasHolder.view?.nudgeSelection(dx: 0, dy: step); return true
            case 126: CanvasHolder.view?.nudgeSelection(dx: 0, dy: -step); return true
            default: break
            }
        }
        return false
    }
}
