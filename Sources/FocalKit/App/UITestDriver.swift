#if DEBUG
import AppKit
import UniformTypeIdentifiers

/// Debug builds only: replays a JSON script (FOCAL_UITEST=/path/script.json) through the real event path
/// (NSEvents sent to the window, so hit testing, zoom conversion and the tools all run as for a person).
/// Coordinates are image pixels; "dump" writes observable state for the test to assert on.
@MainActor
enum UITestDriver {
    private static var steps: [[String: Any]] = []
    private static weak var documents: FocalDocumentController?

    static func start(documents controller: FocalDocumentController) -> Bool {
        guard let path = ProcessInfo.processInfo.environment["FOCAL_UITEST"],
              let data = FileManager.default.contents(atPath: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return false }
        steps = json
        documents = controller
        NSApp.activate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { waitForFocus(tries: 20) }
        return true
    }

    /// macOS may withhold focus while the person is using another app; wait a little, then run anyway
    /// (actions fall back to the window's responder chain).
    private static func waitForFocus(tries: Int) {
        if NSApp.isActive || tries == 0 {
            Log.event("UITEST start active=\(NSApp.isActive)")
            run(0)
            return
        }
        NSApp.activate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { waitForFocus(tries: tries - 1) }
    }

    private static func run(_ index: Int) {
        guard index < steps.count else { Log.event("UITEST DONE"); return }
        let step = steps[index]
        perform(step)
        let wait = (step["wait"] as? Double) ?? 150
        DispatchQueue.main.asyncAfter(deadline: .now() + wait / 1000) { run(index + 1) }
    }

    private static var controller: ViewerWindowController? {
        let viewers = NSApp.orderedWindows.compactMap { $0.windowController as? ViewerWindowController }
        return viewers.first { $0.window?.isKeyWindow == true } ?? viewers.first
    }

    private static func point(_ v: Any?) -> CGPoint {
        let a = (v as? [Double]) ?? [0, 0]
        return CGPoint(x: a[0], y: a[1])
    }

    private static func perform(_ step: [String: Any]) {
        let op = step["op"] as? String ?? ""
        Log.event("UITEST \(op)")
        let wc = controller
        let image = wc?.content as? ImageViewController
        switch op {
        case "open":
            documents?.open(URL(fileURLWithPath: step["path"] as? String ?? ""))
        case "action":
            let sel = Selector(step["name"] as? String ?? "")
            var handled = NSApp.sendAction(sel, to: nil, from: nil)
            if !handled, let window = wc?.window {
                // No key window (focus withheld): walk this window's responder chain, then its controller.
                window.makeKeyAndOrderFront(nil)
                handled = (window.firstResponder ?? window).tryToPerform(sel, with: nil) || wc?.tryToPerform(sel, with: nil) == true
                if !handled, let doc = wc?.document as? NSDocument, doc.responds(to: sel) {
                    doc.perform(sel, with: nil)
                    handled = true
                }
            }
            Log.event("UITEST action \(sel) handled=\(handled) key=\(wc?.window?.isKeyWindow ?? false) active=\(NSApp.isActive)")
        case "markup":
            wc?.markup.isVisible = step["on"] as? Bool ?? true
        case "tool":
            if let t = MarkupState.Tool(rawValue: step["name"] as? String ?? "") { wc?.markup.tool = t }
        case "color":
            wc?.markup.color = RGBAColor.palette[step["index"] as? Int ?? 0].color
        case "drag":
            // Like a real mouse: positions are fixed in window space at the start, so the image moving
            // under the pointer (panning, autoscroll) doesn't feed back into where the pointer goes.
            guard let image else { return }
            let from = windowPoint(point(step["from"]), in: image), to = windowPoint(point(step["to"]), in: image)
            let flags: NSEvent.ModifierFlags = (step["shift"] as? Bool) == true ? .shift : []
            let n = 12
            mouse(.leftMouseDown, atWindow: from, in: image, flags: flags)
            for i in 1...n {
                let t = CGFloat(i) / CGFloat(n)
                mouse(.leftMouseDragged, atWindow: NSPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t), in: image, flags: flags)
            }
            mouse(.leftMouseUp, atWindow: to, in: image, flags: flags)
        case "click":
            guard let image else { return }
            let at = point(step["at"])
            let count = step["count"] as? Int ?? 1
            for c in 1...count {
                mouse(.leftMouseDown, at: at, in: image, clicks: c)
                mouse(.leftMouseUp, at: at, in: image, clicks: c)
            }
        case "scroll":
            guard let image, let window = image.view.window else { return }
            let at = image.canvas.convert(image.canvas.viewPoint(point(step["at"])), to: nil)
            scroll(dy: step["dy"] as? Double ?? 1, at: at, in: window)
        case "scrollText":
            // ⌘ + wheel over a text window (zoom), or a plain wheel (scroll) when "command" is false.
            guard let text = wc?.content as? TextViewController, let window = text.view.window else { return }
            let center = text.view.convert(NSPoint(x: text.view.bounds.midX, y: text.view.bounds.midY), to: nil)
            scroll(dy: step["dy"] as? Double ?? 1, at: center, in: window, command: step["command"] as? Bool ?? true)
        case "key":
            guard let window = wc?.window else { return }
            let chars = step["chars"] as? String ?? ""
            // "mods": ["command", "shift", "option"] sends a key equivalent through the menus, as a person's ⌘S would.
            let names = step["mods"] as? [String] ?? []
            let known: [(String, NSEvent.ModifierFlags)] = [("command", .command), ("shift", .shift), ("option", .option)]
            let mods = known.reduce(into: NSEvent.ModifierFlags()) { flags, pair in if names.contains(pair.0) { flags.insert(pair.1) } }
            Log.event("UITEST key \(chars.debugDescription) mods=\(names) active=\(NSApp.isActive) key=\(window.isKeyWindow)")
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                if let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: mods, timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: window.windowNumber, context: nil, characters: chars,
                                            charactersIgnoringModifiers: chars, isARepeat: false,
                                            keyCode: UInt16(step["code"] as? Int ?? 0)) {
                    NSApp.postEvent(e, atStart: false)   // through the real event loop (closes undo groups per event, as for a person)
                }
            }
        case "type":
            (wc?.window?.firstResponder as? NSTextView)?.insertText(step["text"] as? String ?? "", replacementRange: NSRange(location: NSNotFound, length: 0))
            // A person's typing arrives as events, and undo groups (hence the document's edited state) close only
            // after NSApplication dispatches one. Post an event so this insert is settled like a keystroke.
            if let e = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0,
                                          windowNumber: wc?.window?.windowNumber ?? 0, context: nil, subtype: 0, data1: 0, data2: 0) {
                NSApp.postEvent(e, atStart: false)
            }
        case "resize":
            guard let window = wc?.window else { return }
            let s = point(step["size"])
            var f = window.frame
            f.origin.y += f.height - s.y
            f.size = CGSize(width: s.x, height: s.y)
            window.setFrame(f, display: true)
        case "export":
            if let img = (wc?.document as? ImageDocument)?.flattenedImage() {
                let rep = NSBitmapImageRep(cgImage: img)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: step["path"] as? String ?? ""))
            }
        case "dump":
            dump(to: step["path"] as? String ?? "", wc: wc, image: image)
        case "snap":
            // The app never captures the screen itself (that needs Screen Recording permission). It asks the
            // test runner, which already has it: write "<path>.req" with the window id, wait for "<path>".
            let target: NSWindow? = switch step["which"] as? String {
            case "settings": SettingsWindowController.shared.window
            case "inspector": InspectorController.shared.window
            case "sheet": wc?.window?.attachedSheet
            default: wc?.window
            }
            guard let window = target, let path = step["path"] as? String else { return }
            try? "\(window.windowNumber)".write(toFile: path + ".req", atomically: true, encoding: .utf8)
            let deadline = Date().addingTimeInterval(5)
            while !FileManager.default.fileExists(atPath: path), Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            }
        case "contextMenu":
            let target: NSView? = image?.canvas ?? (wc?.content as? TextViewController)?.textView
            guard let target, let window = target.window else { return }
            let location = image.map { windowPoint(point(step["at"]), in: $0) } ?? target.convert(NSPoint(x: 60, y: 40), to: nil)
            guard let e = NSEvent.mouseEvent(with: .rightMouseDown, location: location, modifierFlags: [], timestamp: 0,
                                             windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1),
                  let menu = target.menu(for: e) else { return }
            menu.update()   // runs validation through the responder chain, as a real right-click would
            let items = menu.items.filter { !$0.isSeparatorItem }.map { "\($0.title)=\($0.isEnabled ? "on" : "off")" }
            Log.event("UITEST contextMenu \(items.joined(separator: ", "))")
        case "clipboard":
            let pb = NSPasteboard.general
            let png = pb.data(forType: .png).flatMap(NSBitmapImageRep.init(data:))
            Log.event("UITEST clipboard types=\(pb.types?.map(\.rawValue).filter { $0.hasPrefix("public") } ?? []) png=\(png.map { "\($0.pixelsWide)x\($0.pixelsHigh)" } ?? "none")")
        case "js":
            // Evaluate in the rendered Markdown and log the answer (async: give the step a wait).
            guard let page = (wc?.content as? TextViewController)?.preview else { Log.event("UITEST js no preview"); return }
            let expr = step["expr"] as? String ?? ""
            page.webView.evaluateJavaScript(expr) { value, error in
                Log.event("UITEST js \(expr) => \(value.map { "\($0)" } ?? "nil") \(error.map { "error=\($0)" } ?? "")")
            }
        case "saveAs":
            // Save As to a path through the same completion the Save sheet uses. The real sheet can't be pressed
            // from here: it runs out of process (NSSavePanel ok: throws "not implemented" and crashed the run).
            guard let doc = wc?.document as? NSDocument, let content = wc?.content, let path = step["path"] as? String else { return }
            let url = URL(fileURLWithPath: path)
            let type = UTType(filenameExtension: url.pathExtension)?.identifier ?? doc.fileType ?? "public.plain-text"
            Log.event("UITEST saveAs \(url.lastPathComponent) type=\(type)")
            doc.save(to: url, ofType: type, for: .saveAsOperation, delegate: content,
                     didSave: NSSelectorFromString("document:didSave:contextInfo:"), contextInfo: nil)
        case "saveTo":
            // Export (File ▸ Export…, Export as PDF…) to a path, as saveAs but leaving the document where it is.
            guard let doc = wc?.document as? NSDocument, let wc, let path = step["path"] as? String else { return }
            let url = URL(fileURLWithPath: path)
            let type = UTType(filenameExtension: url.pathExtension)?.identifier ?? doc.fileType ?? "public.png"
            Log.event("UITEST saveTo \(url.lastPathComponent) type=\(type)")
            wc.export(doc, to: url, type: type)
        case "openSet":
            // Several files at once, as from a Finder selection.
            documents?.open((step["paths"] as? [String] ?? []).map { URL(fileURLWithPath: $0) })
        case "sidebarClick":
            // A real mouse click on a sidebar row (through the event loop, like a person's).
            guard let wc, let window = wc.window, let row = step["row"] as? Int, wc.sidebarVisible else { return }
            let table = wc.sidebar.table
            let rect = table.rect(ofRow: row)
            let point = table.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
            let hit = window.contentView?.superview?.hitTest(point)
            Log.event("UITEST sidebarClick row=\(row) rect=\(NSStringFromRect(rect)) windowPoint=\(NSStringFromPoint(point)) rowAtPoint=\(table.row(at: table.convert(point, from: nil))) hit=\(hit.map { String(describing: type(of: $0)) } ?? "nil") tableFrame=\(NSStringFromRect(table.frame)) key=\(window.isKeyWindow) active=\(NSApp.isActive) firstMouse=\(hit?.acceptsFirstMouse(for: nil) ?? false)")
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                if let e = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                    NSApp.postEvent(e, atStart: false)
                }
            }
        case "revert":
            // Revert to Saved without its confirmation sheet (a sheet would block the script).
            if let doc = wc?.document as? NSDocument, let url = doc.fileURL, let type = doc.fileType {
                do { try doc.revert(toContentsOf: url, ofType: type) } catch { Log.event("UITEST revert failed \(error)") }
            }
        case "terminate":
            NSApp.terminate(nil)
        case "quit":
            Log.event("UITEST DONE")
            exit(0)
        default:
            if !performPDF(op, step, wc: wc) { Log.event("UITEST unknown op \(op)") }
        }
    }

    private static func windowPoint(_ imagePoint: CGPoint, in image: ImageViewController) -> NSPoint {
        image.canvas.convert(image.canvas.viewPoint(imagePoint), to: nil)
    }

    private static func mouse(_ type: NSEvent.EventType, at imagePoint: CGPoint, in image: ImageViewController,
                              clicks: Int = 1, flags: NSEvent.ModifierFlags = []) {
        mouse(type, atWindow: windowPoint(imagePoint, in: image), in: image, clicks: clicks, flags: flags)
    }

    private static func mouse(_ type: NSEvent.EventType, atWindow location: NSPoint, in image: ImageViewController,
                              clicks: Int = 1, flags: NSEvent.ModifierFlags = []) {
        guard let window = image.view.window else { return }
        guard let e = NSEvent.mouseEvent(with: type, location: location, modifierFlags: flags,
                                         timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                         context: nil, eventNumber: 0, clickCount: clicks,
                                         pressure: type == .leftMouseUp ? 0 : 1) else { return }
        NSApp.postEvent(e, atStart: false)   // through the real event loop (closes undo groups per event, as for a person)
    }

    /// A line-based (mouse wheel) scroll event at a window location.
    private static func scroll(dy: Double, at location: NSPoint, in window: NSWindow, command: Bool = false) {
        guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: Int32(dy), wheel2: 0, wheel3: 0) else { return }
        if command { cg.flags = .maskCommand }
        let screen = window.convertPoint(toScreen: location)
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        cg.location = CGPoint(x: screen.x, y: mainHeight - screen.y)   // Quartz: top-left origin
        cg.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(window.windowNumber))
        cg.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(window.windowNumber))
        guard let e = NSEvent(cgEvent: cg) else { return }
        // A synthesized scroll carries no window (its location is in screen coordinates), so NSWindow can't
        // route it; deliver it to the view under the point the way the window server would.
        let target = window.contentView?.hitTest(window.contentView!.convert(location, from: nil))
        Log.event("UITEST scroll event window=\(e.window?.windowNumber ?? -1) target=\(target.map { String(describing: type(of: $0)) } ?? "nil") dy=\(e.scrollingDeltaY) inverted=\(e.isDirectionInvertedFromDevice)")
        target?.scrollWheel(with: e)
    }

    private static func viewClasses(in view: NSView?) -> [String] {
        guard let view else { return [] }
        return [String(describing: type(of: view))] + view.subviews.flatMap { viewClasses(in: $0) }
    }

    static func rect(_ r: NSRect) -> [Double] { [r.minX, r.minY, r.width, r.height].map(Double.init) }

    private static func dump(to path: String, wc: ViewerWindowController?, image: ImageViewController?) {
        var d: [String: Any] = [:]
        if let wc, let window = wc.window, let cv = window.contentView {
            d["frame"] = rect(window.frame)
            d["content"] = rect(window.convertToScreen(cv.frame))
            d["title"] = window.title
            d["subtitle"] = window.subtitle
            d["edited"] = window.isDocumentEdited
            d["sheet"] = window.attachedSheet.map { sheet in
                ([sheet.title] + (sheet.contentView?.subviews.compactMap { ($0 as? NSTextField)?.stringValue } ?? [])).joined(separator: " | ")
            } ?? ""
            d["markupVisible"] = wc.markup.isVisible
            d["toolbarVisible"] = window.toolbar?.isVisible ?? false
            d["markupTool"] = wc.markup.tool.rawValue
            d["toast"] = (wc.content?.view.subviews.first { $0.identifier?.rawValue == "FocalToast" }?
                .subviews.compactMap { ($0 as? NSTextField)?.stringValue }.first) ?? ""
            if let save = window.toolbar?.items.first(where: { $0.itemIdentifier.rawValue == "save" }) {
                window.toolbar?.validateVisibleItems()
                d["saveButtonEnabled"] = save.isEnabled
            }
            d["windowCount"] = NSApp.windows.filter { $0.isVisible && $0.windowController is ViewerWindowController }.count
            d["fileType"] = (wc.document as? NSDocument)?.fileType ?? ""
            d["inspectorVisible"] = InspectorController.shared.window?.isVisible ?? false
            d["file"] = (wc.document as? NSDocument)?.fileURL?.lastPathComponent ?? ""
            d["contentKind"] = wc.content.map { String(describing: type(of: $0)) } ?? ""
            d["windowToolbar"] = window.toolbar?.identifier ?? ""
            d["markupBarShown"] = window.titlebarAccessoryViewControllers.contains { $0 is MarkupAccessoryController }
            if let pdf = wc.content as? PDFViewerController { d.merge(pdfDump(pdf)) { $1 } }
            if let model = wc.content as? ModelViewController, let s = model.stats {
                d["modelMeshes"] = s.meshes
                d["modelTriangles"] = s.triangles
                d["modelSize"] = [s.size.x, s.size.y, s.size.z].map(Double.init)
                d["modelTempFiles"] = model.document.temporaryFiles.count
            }
            if let image, image.document.pageCount > 1 {
                d["page"] = image.document.page
                d["pageCount"] = image.document.pageCount
                d["pageStripVisible"] = image.pageStripVisible
                d["pageStripRows"] = image.pageStrip.table.numberOfRows
                d["pageStripSelected"] = image.pageStrip.table.selectedRow
                d["pageLabels"] = (0..<image.document.pageCount).map(image.pageLabel(for:))
                d["editedPages"] = image.document.editedPages.sorted()
            }
            d["responder"] = window.firstResponder.map { String(describing: type(of: $0)) } ?? ""
            d["sidebarVisible"] = wc.sidebarVisible
            if wc.sidebarVisible {
                d["sidebarFiles"] = wc.sidebar.files.map(\.lastPathComponent)
                d["sidebarSelectedRow"] = wc.sidebar.table.selectedRow
                d["sidebarThumbnails"] = wc.sidebar.loadedThumbnailCount
                d["mediaFrame"] = rect(window.convertToScreen(wc.content?.view.convert(wc.content?.view.bounds ?? .zero, to: nil) ?? .zero))
            }
            d["contentAspectRatio"] = [Double(window.contentAspectRatio.width), Double(window.contentAspectRatio.height)]
        }
        d["mainVisible"] = rect(NSScreen.screens.first?.visibleFrame ?? .zero)
        if let text = wc?.content as? TextViewController {
            d["fontSize"] = Double(text.fontSize)
            d["mode"] = text.mode == .preview ? "preview" : "edit"
            d["textFormat"] = "\(text.document.format)"
            d["toolbarId"] = text.view.window?.toolbar?.identifier ?? ""
            d["firstResponder"] = text.view.window?.firstResponder.map { String(describing: type(of: $0)) } ?? ""
            d["magnification"] = Double(text.scrollView.magnification)
            if let page = text.preview {
                d["previewLoaded"] = page.loaded
                d["pageZoom"] = Double(page.webView.pageZoom)
                d["previewFindBar"] = page.isFindBarVisible
                d["previewHidden"] = page.isHidden
            }
            if text.isRich, text.document.storage.length > 0 {
                let font = text.document.storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
                let traits = font.map { NSFontManager.shared.traits(of: $0) } ?? []
                d["richFirstBold"] = traits.contains(.boldFontMask)
                d["richFirstItalic"] = traits.contains(.italicFontMask)
                d["richFirstFont"] = font.map { "\($0.fontName) \($0.pointSize)" } ?? ""
                d["windowViews"] = Self.viewClasses(in: text.view.window?.contentView?.superview).filter { $0.contains("Inspector") || $0.contains("Ruler") }
            }
            d["text"] = String(text.document.text.prefix(4000))
            d["textEditable"] = text.textView.isEditable
            let storage = text.document.storage
            d["storageFontSize"] = storage.length > 0 ? Double((storage.attribute(.font, at: storage.length - 1, effectiveRange: nil) as? NSFont)?.pointSize ?? 0) : 0
            d["undoTitle"] = text.document.undoManager?.undoMenuItemTitle ?? ""
            d["smartQuotes"] = text.textView.isAutomaticQuoteSubstitutionEnabled
            d["prefTextSize"] = Double(Prefs.textFontSize)
            let tv = text.textView
            d["scrollContentWidth"] = Double(tv.enclosingScrollView?.contentSize.width ?? 0)
            d["textViewWidth"] = Double(tv.frame.width)
            d["containerWidth"] = Double(tv.textContainer?.size.width ?? 0)
            d["lineFragmentPadding"] = Double(tv.textContainer?.lineFragmentPadding ?? 0)
            d["insetWidth"] = Double(tv.textContainerInset.width)
            d["charWidth"] = Double(("0" as NSString).size(withAttributes: [.font: tv.font ?? NSFont.systemFont(ofSize: 12)]).width)
            d["scrollerStyleLegacy"] = NSScroller.preferredScrollerStyle == .legacy
            d["verticalScrollerWidth"] = Double(tv.enclosingScrollView?.verticalScroller?.frame.width ?? -1)
        }
        if let image {
            d["magnification"] = Double(image.magnification)
            d["fit"] = Double(image.fitMagnification())
            d["clip"] = rect(image.clipBounds)
            if let sv = image.canvas.enclosingScrollView {
                d["scrollFrame"] = rect(sv.frame)
                d["contentInsets"] = [sv.contentInsets.top, sv.contentInsets.left, sv.contentInsets.bottom, sv.contentInsets.right].map(Double.init)
                d["clipFrame"] = rect(sv.contentView.frame)
            }
            d["canvas"] = rect(image.canvas.frame)
            let state = image.document.state
            d["annotations"] = state?.annotations.map { ["kind": $0.kind.rawValue, "points": $0.points.flatMap { [Double($0.x), Double($0.y)] },
                                                         "text": $0.text] } ?? []
            d["imageSize"] = state.map { [$0.image.width, $0.image.height] } ?? []
            d["crop"] = state?.crop.map(rect) ?? []
            d["selected"] = image.canvas.selectedID?.uuidString ?? ""
        }
        if let data = try? JSONSerialization.data(withJSONObject: d, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }
}
#endif
