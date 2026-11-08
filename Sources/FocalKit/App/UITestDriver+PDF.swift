#if DEBUG
import AppKit
import PDFKit

/// PDF steps for the test driver. Page positions are PDF page points (origin bottom-left), pages from 0.
extension UITestDriver {
    static func performPDF(_ op: String, _ step: [String: Any], wc: ViewerWindowController?) -> Bool {
        guard let pdf = wc?.content as? PDFViewerController else { return false }
        let pageIndex = step["page"] as? Int ?? 0
        switch op {
        case "pdfDrag":
            // Like a person's drag: down, twelve moves, up, at fixed window positions.
            guard let page = pdf.document.pdf.page(at: pageIndex) else { return true }
            reveal(pagePoint(step["from"]), pagePoint(step["to"]), on: page, in: pdf)
            let from = windowPoint(pagePoint(step["from"]), on: page, in: pdf), to = windowPoint(pagePoint(step["to"]), on: page, in: pdf)
            post(.leftMouseDown, at: from, in: pdf)
            for i in 1...12 {
                let t = CGFloat(i) / 12
                post(.leftMouseDragged, at: NSPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t), in: pdf)
            }
            post(.leftMouseUp, at: to, in: pdf)
        case "pdfClick":
            guard let page = pdf.document.pdf.page(at: pageIndex) else { return true }
            reveal(pagePoint(step["at"]), pagePoint(step["at"]), on: page, in: pdf)
            let at = windowPoint(pagePoint(step["at"]), on: page, in: pdf)
            let clicks = step["clicks"] as? Int ?? 1
            for n in 1...clicks {
                post(.leftMouseDown, at: at, in: pdf, clicks: n)
                post(.leftMouseUp, at: at, in: pdf, clicks: n)
            }
        case "search":
            let text = step["text"] as? String ?? ""
            wc?.setSearchText(text)
            pdf.search(text)
        case "find":
            let item = NSMenuItem()
            item.tag = (step["do"] as? String == "previous" ? NSTextFinder.Action.previousMatch : .nextMatch).rawValue
            pdf.performFindPanelAction(item)
        case "contents":
            pdf.sidePanel.showContents(selecting: step["row"] as? Int ?? 0)
        case "goPage":
            pdf.goTo(pageIndex)
        case "pages":
            let rows = IndexSet(step["rows"] as? [Int] ?? [pageIndex])
            switch step["do"] as? String {
            case "move": pdf.movePages(rows, to: step["to"] as? Int ?? 0)
            case "delete": pdf.deletePages(rows)
            case "rotate": pdf.rotatePages(rows, clockwise: step["clockwise"] as? Bool ?? true)
            case "blank": pdf.insertBlankPage(at: step["to"] as? Int ?? 0)
            case "insert": pdf.insertFiles((step["files"] as? [String] ?? []).map { URL(fileURLWithPath: $0) }, at: step["to"] as? Int ?? 0)
            default: break
            }
        case "unlock":
            _ = pdf.document.unlock(with: step["password"] as? String ?? "")
        case "endText":
            pdf.endTextEditing(commit: step["commit"] as? Bool ?? true)
        case "setSignature":
            // A stored signature without the drawing sheet (a zig-zag in a 3:1 box).
            let strokes: [[CGPoint]] = [[CGPoint(x: 0, y: 0), CGPoint(x: 40, y: 30), CGPoint(x: 80, y: 0), CGPoint(x: 120, y: 30)]]
            if let sig = SignatureStore.normalize(strokes) { try? SignatureStore.save(sig) }
        case "sheetText":
            // Fill the text area of the sheet showing (a note) and press one of its buttons.
            guard let sheet = wc?.window?.attachedSheet, let content = sheet.contentView else { return true }
            if let textView = textViews(in: content).first {
                textView.string = step["text"] as? String ?? ""
            } else {   // a one-line field (the password sheet)
                fields(in: content).first?.stringValue = step["text"] as? String ?? ""
            }
            let title = step["button"] as? String ?? ""
            buttons(in: content).first { $0.title == title }?.performClick(nil)
        default:
            return false
        }
        return true
    }

    static func pdfDump(_ pdf: PDFViewerController) -> [String: Any] {
        let doc = pdf.document.pdf
        var d: [String: Any] = [
            "pdfPage": pdf.currentPageIndex,
            "pdfPageCount": doc.pageCount,
            "pdfLocked": doc.isLocked,
            "pdfScale": Double(pdf.pdfView.scaleFactor),
            "pdfDisplayMode": pdf.pdfView.displayMode.rawValue,
            "pdfSidePanel": pdf.sidePanelVisible,
            "pdfShowsContents": pdf.sidePanel.showsContents,
            "pdfOutlineCount": doc.outlineRoot?.numberOfChildren ?? 0,
            "pdfMatches": pdf.matches.count,
            "pdfMatchIndex": pdf.matchIndex,
            "pdfCanAnnotate": pdf.document.canAnnotate,
            "pdfSelectedMark": pdf.selectedMark?.annotation.type ?? "",
            "pdfPendingCrop": pdf.pendingCrop != nil,
            "pdfEditing": pdf.textEditor != nil,
            "pdfStripRows": pdf.sidePanel.strip.table.numberOfRows,
            "pdfSelection": pdf.pdfView.currentSelection?.string ?? "",
            "pdfDocEdited": pdf.document.isDocumentEdited,
            "pdfCanUndo": pdf.document.undoManager?.canUndo ?? false,
            "pdfUndoLevel": pdf.document.undoManager?.groupingLevel ?? -1,
            "pdfActiveTool": pdf.activeTool.rawValue,
            "pdfKeyWindow": pdf.view.window?.isKeyWindow ?? false,
        ]
        d["pdfPages"] = (0..<doc.pageCount).compactMap { i -> [String: Any]? in
            guard let page = doc.page(at: i) else { return nil }
            return [
                "text": String((page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(24)),
                "rotation": page.rotation,
                "crop": rect(page.bounds(for: .cropBox)),
                "marks": page.annotations.filter(PDFMarks.isMarkup).map { a -> [String: Any] in
                    ["type": a.type ?? "", "contents": a.contents ?? "", "bounds": rect(a.bounds)]
                },
            ]
        }
        return d
    }

    /// Scroll so the points are on screen (a click outside the window reaches nothing, as for a person).
    private static func reveal(_ a: CGPoint, _ b: CGPoint, on page: PDFPage, in pdf: PDFViewerController) {
        let area = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y)).insetBy(dx: -40, dy: -40)
        let visible = pdf.pdfView.convert(pdf.pdfView.bounds, to: page)
        guard pdf.pdfView.currentPage != page || !visible.contains(area) else { return }
        pdf.pdfView.go(to: area, on: page)
        pdf.view.layoutSubtreeIfNeeded()
    }

    private static func pagePoint(_ v: Any?) -> CGPoint {
        let a = (v as? [Double]) ?? [0, 0]
        return CGPoint(x: a[0], y: a[1])
    }

    private static func windowPoint(_ p: CGPoint, on page: PDFPage, in pdf: PDFViewerController) -> NSPoint {
        pdf.pdfView.convert(pdf.pdfView.convert(p, from: page), to: nil)
    }

    private static func post(_ type: NSEvent.EventType, at location: NSPoint, in pdf: PDFViewerController, clicks: Int = 1) {
        guard let window = pdf.view.window, let e = NSEvent.mouseEvent(
            with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: type == .leftMouseUp ? 0 : 1)
        else { return }
        NSApp.postEvent(e, atStart: false)
    }

    private static func textViews(in view: NSView) -> [NSTextView] {
        (view as? NSTextView).map { [$0] } ?? view.subviews.flatMap(textViews)
    }

    private static func fields(in view: NSView) -> [NSTextField] {
        (view as? NSTextField).flatMap { $0.isEditable ? [$0] : nil } ?? view.subviews.flatMap(fields)
    }

    private static func buttons(in view: NSView) -> [NSButton] {
        (view as? NSButton).map { [$0] } ?? view.subviews.flatMap(buttons)
    }
}
#endif
