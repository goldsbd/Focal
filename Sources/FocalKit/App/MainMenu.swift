import AppKit
import PDFKit

/// The menu bar, built in code (no nib keeps launch fast). Shortcuts follow Preview and QuickTime.
@MainActor
enum MainMenu {
    static func build() -> NSMenu {
        let bar = NSMenu()
        for menu in [appMenu(), fileMenu(), editMenu(), viewMenu(), formatMenu(), toolsMenu(), goMenu(), windowMenu(), helpMenu()] {
            let holder = NSMenuItem()
            holder.submenu = menu
            bar.addItem(holder)
        }
        return bar
    }

    private static func item(_ title: String, _ action: Selector?, _ key: String = "",
                             _ mods: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.keyEquivalentModifierMask = mods
        return i
    }

    /// Text find bar items: one action, the tag says which (NSTextFinder.Action).
    private static func findItem(_ title: String, _ action: NSTextFinder.Action, _ key: String,
                                 _ mods: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let i = item(title, #selector(NSTextView.performFindPanelAction(_:)), key, mods)
        i.tag = action.rawValue
        return i
    }

    /// PDF page layout; the tag carries the PDFDisplayMode.
    private static func displayMode(_ title: String, _ mode: PDFDisplayMode) -> NSMenuItem {
        let i = item(title, #selector(PDFViewerController.setPDFDisplayMode(_:)))
        i.tag = mode.rawValue
        return i
    }

    private static func menu(_ title: String, _ items: [NSMenuItem]) -> NSMenu {
        let m = NSMenu(title: title)
        items.forEach(m.addItem)
        return m
    }

    private static func appMenu() -> NSMenu {
        let services = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        let servicesMenu = NSMenu(title: "Services")
        services.submenu = servicesMenu
        NSApp.servicesMenu = servicesMenu
        return menu("Focal", [
            item("About Focal", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            .separator(),
            item("Settings…", #selector(AppDelegate.showSettings(_:)), ","),
            .separator(),
            services,
            .separator(),
            item("Hide Focal", #selector(NSApplication.hide(_:)), "h"),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            item("Show All", #selector(NSApplication.unhideAllApplications(_:))),
            .separator(),
            item("Quit Focal", #selector(NSApplication.terminate(_:)), "q"),
        ])
    }

    private static func fileMenu() -> NSMenu {
        let recent = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
        recent.submenu = menu("Open Recent", [item("Clear Menu", #selector(NSDocumentController.clearRecentDocuments(_:)))])
        return menu("File", [
            item("New from Clipboard", #selector(AppDelegate.newFromClipboard(_:)), "n"),
            item("New Text File", #selector(AppDelegate.newTextFile(_:)), "n", [.command, .option]),
            item("Open…", #selector(NSDocumentController.openDocument(_:)), "o"),
            recent,
            .separator(),
            item("Close", #selector(NSWindow.performClose(_:)), "w"),
            item("Save", #selector(ImageViewController.quickSave(_:)), "s"),
            item("Save As…", #selector(NSDocument.saveAs(_:)), "s", [.command, .shift]),
            item("Export…", #selector(NSDocument.saveTo(_:))),
            item("Export as PDF…", #selector(ViewerWindowController.exportAsPDF(_:))),
            item("Rename…", #selector(NSDocument.rename(_:))),
            item("Move To…", #selector(NSDocument.move(_:))),
            item("Revert to Saved", #selector(NSDocument.revertToSaved(_:))),
            .separator(),
            item("Show in Finder", #selector(ViewerWindowController.showInFinder(_:)), "r", [.command, .option]),
            item("Move to Trash", #selector(ViewerWindowController.moveToTrash(_:)), "\u{8}"),
            .separator(),
            item("Print…", #selector(NSDocument.printDocument(_:)), "p"),
        ])
    }

    private static func editMenu() -> NSMenu {
        menu("Edit", [
            item("Undo", Selector(("undo:")), "z"),
            item("Redo", Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item("Cut", #selector(NSText.cut(_:)), "x"),
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"),
            item("Delete", #selector(NSText.delete(_:))),
            item("Select All", #selector(NSText.selectAll(_:)), "a"),
            .separator(),
            findItem("Find…", .showFindInterface, "f"),
            findItem("Find and Replace…", .showReplaceInterface, "f", [.command, .option]),
            findItem("Find Next", .nextMatch, "g"),
            findItem("Find Previous", .previousMatch, "g", [.command, .shift]),
            findItem("Use Selection for Find", .setSearchString, "e"),
            .separator(),
            item("Trim…", #selector(VideoViewController.trimMovie(_:)), "t"),
            .separator(),
            item("Insert Page from File…", #selector(PDFViewerController.insertPageFromFile(_:)), "i", [.command, .option]),
            item("Insert Blank Page", #selector(PDFViewerController.insertBlankPageAfterCurrent(_:))),
            item("Delete Page", #selector(PDFViewerController.deleteCurrentPage(_:))),
        ])
    }

    private static func viewMenu() -> NSMenu {
        menu("View", [
            item("Actual Size", #selector(ImageViewController.actualSize(_:)), "0"),
            item("Zoom to Fit", #selector(ImageViewController.zoomToFit(_:)), "9"),
            item("Zoom In", #selector(ImageViewController.zoomIn(_:)), "="),
            item("Zoom Out", #selector(ImageViewController.zoomOut(_:)), "-"),
            .separator(),
            item("Show Markup Toolbar", #selector(ImageViewController.toggleMarkup(_:)), "a", [.command, .shift]),
            item("Preview Markdown", #selector(TextViewController.togglePreview(_:)), "p", [.command, .shift]),
            item("Show Sidebar", #selector(ViewerWindowController.toggleFileSidebar(_:)), "s", [.command, .option]),
            item("Show Page Thumbnails", #selector(ImageViewController.togglePageStrip(_:)), "2", [.command, .option]),
            .separator(),
            displayMode("Continuous Scroll", .singlePageContinuous),
            displayMode("Single Page", .singlePage),
            displayMode("Two Pages", .twoUpContinuous),
            .separator(),
            item("Loop", #selector(VideoViewController.toggleLoop(_:)), "l", [.command, .option]),
            .separator(),
            item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]),
        ])
    }

    /// Rich text (RTF) formatting. Inside rich text ⌘B/⌘I/⌘U/⌘T are handled by the text view itself
    /// (ZoomableTextView), ahead of the app-wide ⌘I Inspector and ⌘T Trim, so they're shown here without keys
    /// that would collide in the menu bar.
    private static func formatMenu() -> NSMenu {
        let fonts = item("Show Fonts", #selector(NSFontManager.orderFrontFontPanel(_:)))
        fonts.target = NSFontManager.shared
        let bigger = item("Bigger", #selector(NSFontManager.modifyFont(_:)))
        bigger.target = NSFontManager.shared
        bigger.tag = Int(NSFontAction.sizeUpFontAction.rawValue)
        let smaller = item("Smaller", #selector(NSFontManager.modifyFont(_:)))
        smaller.target = NSFontManager.shared
        smaller.tag = Int(NSFontAction.sizeDownFontAction.rawValue)
        return menu("Format", [
            fonts,
            item("Bold", #selector(TextViewController.toggleBold(_:)), "b"),
            item("Italic", #selector(TextViewController.toggleItalic(_:))),
            item("Underline", #selector(NSText.underline(_:)), "u"),
            bigger, smaller,
            .separator(),
            item("Align Left", #selector(NSText.alignLeft(_:)), "{"),
            item("Center", #selector(NSText.alignCenter(_:)), "|"),
            item("Justify", #selector(NSTextView.alignJustified(_:))),
            item("Align Right", #selector(NSText.alignRight(_:)), "}"),
            .separator(),
            item("Show Ruler", #selector(NSText.toggleRuler(_:))),
            item("Show Colors", #selector(NSApplication.orderFrontColorPanel(_:)), "c", [.command, .shift]),
        ])
    }

    private static func toolsMenu() -> NSMenu {
        menu("Tools", [
            item("Rotate Left", #selector(ImageViewController.rotateLeft(_:)), "l"),
            item("Rotate Right", #selector(ImageViewController.rotateRight(_:)), "r"),
            item("Crop", #selector(ImageViewController.cropToSelection(_:)), "k"),
            item("Create Signature…", #selector(PDFViewerController.createSignature(_:))),
            .separator(),
            item("Show Inspector", #selector(AppDelegate.showInspector(_:)), "i"),
        ])
    }

    private static func goMenu() -> NSMenu {
        menu("Go", [
            item("Previous File", #selector(ViewerWindowController.previousFile(_:)), "["),
            item("Next File", #selector(ViewerWindowController.nextFile(_:)), "]"),
            .separator(),
            item("Previous Page", #selector(ImageViewController.previousPage(_:)), "\u{F700}", [.command, .option]),
            item("Next Page", #selector(ImageViewController.nextPage(_:)), "\u{F701}", [.command, .option]),
            item("Go to Page…", #selector(ImageViewController.goToPage(_:)), "g", [.command, .option]),
        ])
    }

    private static func windowMenu() -> NSMenu {
        let m = menu("Window", [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Zoom", #selector(NSWindow.performZoom(_:))),
            .separator(),
            item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))),
        ])
        NSApp.windowsMenu = m
        return m
    }

    private static func helpMenu() -> NSMenu {
        let m = NSMenu(title: "Help")
        NSApp.helpMenu = m
        return m
    }
}
