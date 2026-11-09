# Focal

Native macOS replacement for **Preview (images, PDFs, 3D), QuickTime Player and a text viewer/editor**, built for one user on a 40"
ultrawide. Swift 6.4 (strict concurrency) + AppKit, SwiftUI only for Settings. SwiftPM; no Xcode project.
Bundle id `ai.digitalzoo.focal`, installed at `~/Applications/Focal.app`. Targets **macOS 27+ on Apple silicon only**:
the one setup we can test (no Intel Mac, no older macOS), so don't lower it untested. GitHub `goldsbd/Focal`, private
until the user says otherwise; its history must never carry the user's personal email (commit as the GitHub no-reply
address). `scripts/release.sh` makes the notarized DMG.

## Non-negotiable behaviour (the user asked for each of these)

- **Windows open centered on the main display** (`NSScreen.screens[0]`, the one set in System Settings → Displays),
  with the *content* centered on that point. Never AppKit's top-left cascade: that left-hand placement is why
  this app exists. Settings offers "center of main display", "display with the pointer", "where I last left a window".
- Opens fast (about 360 ms cold to window, about 55 ms file-to-window when running). One window per file.
- Images: wheel zooms at the pointer, the pointer is a hand and dragging pans, **no scroll bars**. Resizing the window
  re-fits live. Markup tools show by default; windows start on the Move/Select hand tool.
- Save without the menu bar: toolbar **Save** button, ⌘S, right-click Save, all confirmed by a toast.
- Text: big and zoomable, **one remembered text size** (`textFontSize`, default 18) drives plain text, the rendered
  Markdown page and RTF zoom. The plain wheel scrolls; ⌘-scroll / pinch / ⌘± zoom.
- Text is editable; Markdown opens **rendered** (Preview | Edit, ⇧⌘P); RTF/RTFD edit with AppKit's format bar;
  File ▸ New Text File (⌥⌘N) saves under any extension (`notes.md` becomes Markdown). ⌘N stays New from Clipboard.
- Video replaces QuickTime: hardware decode/HDR via AVPlayerView, passthrough trim (⌘T), loop, copy frame. The wheel over a
  movie is AVPlayerView's own scrub (measured: 20 ms per wheel line or trackpad point, not frame-snapped); ← → step exact
  frames.
- **PDFs as Preview does them**: page panel (⌥⌘2; reorder by drag, ⌫ deletes, drop files to insert, Contents tab),
  toolbar search (⌘G steps), Markup bar with PDF tools (highlight/underline/strike on selected text, pen, shapes,
  text box, note, signature, redaction, page crop), form filling, rotate, Print, password PDFs stay encrypted on save.
- **Multi-page images** (TIFF pages, icon sizes) get the same page strip; each page edits separately and Save
  rewrites them all. **3D files** (USD/USDZ, glTF, OBJ, STL, PLY, Alembic, MaterialX) open in SceneKit.
- **A folder** dropped on the Dock icon or picked in Open browses its files in one window. BMP, GIF, TGA, SGI,
  icons and JPEG 2000 save in place; Export adds OpenEXR and PDF; File ▸ Export as PDF….
- Browse without reopening: ⌘[ ⌘] (and ← → on images) step through the folder in place. **Several files opened
  together share one window with a thumbnail sidebar**; clicking or ↑↓ switches the viewer to that file's type.
  ⌥⌘S shows a single file's folder in the sidebar. While browsing, the window keeps its size (lightbox).
- **Never reset the user's own settings** (`defaults read ai.digitalzoo.focal`). "Off-center" windows have been the
  user's `rememberLastPosition` choice before; check it before calling it a bug.

## Commands

```bash
swift build                          # compile check
swift test                           # unit tests (Swift Testing), ~60 tests, <1 s
scripts/install.sh                   # release build → ~/Applications/Focal.app (quits a running Focal gracefully; stops if it won't)
CONFIG=debug scripts/build-app.sh    # "Focal Dev.app" (bundle id ai.digitalzoo.focal.dev) for UI tests
scripts/uitest.sh steps.json [log]   # drive Focal Dev through a JSON script (see below)
FOCAL_LOG=1                          # env var: timing log to stderr ("window shown", "open … completed in N ms")
FOCAL_APPEARANCE=dark                # env var, debug builds: Focal Dev runs dark without changing the system's setting (`open --env`, at launch)
swift scripts/launch-bench.swift APP FILE OWNER   # launch-to-window time measured from the window server
```

Builds land in `build.noindex/` so Spotlight never lists a second "Focal". Install only after tests and a UI run
pass; `install.sh` unregisters the build copy so only `~/Applications/Focal.app` appears in Open With.

## Layout

| Folder (`Sources/FocalKit/`) | What lives there |
|---|---|
| `App/` | `FocalApp`/`AppDelegate`, `FocalDocumentController` (open, New Text File, New from Clipboard), `MainMenu` (Preview/QuickTime shortcuts), `UITestDriver` (DEBUG only) |
| `Window/` | `ViewerWindowController` (one per file or set: placement, toolbar per content kind, ⌘[ ⌘] navigation, sidebar, Markup bar), `FileSidebar` (Quick Look thumbnails, virtualised table), `PageStrip` (page thumbnails for PDFs and multi-page images, page editing hooks, Go to Page), `WindowPlacement` (pure, unit-tested), `ViewerToolbar`, `FolderNavigator` (folder order, `browsable`, `folderToBrowse`, what counts as viewable) |
| `Image/` | `ImageDocument` (ImageIO probe then off-main decode; pages; edits as snapshot undo), `ImageViewController` + `+Pages`, `CanvasView` (tools, pan, context menu), `ZoomingScrollView`, `ImageExporter` (incl. multi-page and animated copies), `ImageFormats` (SGI encoder, XBM decoder) |
| `PDF/` | `PDFFileDocument` (PDFKit; every change an undo step; encryption, redaction flattening, print), `PDFViewerController` + `+Markup` (overlay, tools, marks, text boxes, notes) + `+Pages` (page panel, Contents outline), `SignatureStore` (signing sheet, kept per build) |
| `Model/` | `ModelLoader` (SceneKit, glTF via `/usr/bin/usdcat`, MaterialX on a sphere, scene stats), `ModelViewController` + `ModelDocument` |
| `Markup/` | Vector `Annotation`s in image-pixel coordinates, `AnnotationRenderer` (shared by screen and export), `MarkupState`, `MarkupAccessoryController` |
| `Video/` | `VideoDocument`, `VideoViewController` (AVPlayerView, trim, loop), `VideoProbe` (codec, fps, HDR) |
| `Text/` | `TextDocument` (owns the `NSTextStorage`; all text formats), `TextFormat`, `TextDecoding` (encoding/BOM/line endings both ways), `TextViewController` + `+Markdown` + `+Rich`, `ZoomableTextView`, `MarkdownRenderer` (cmark-gfm → HTML+CSS), `MarkdownPreview` (WKWebView) |
| `Settings/`, `Support/` | SwiftUI Settings; `Prefs` (all UserDefaults keys), `Toast`, `InspectorController`, `DefaultApp`, `PasteboardImage`, `InEvent`, `Log` |

`Resources/Info.plist` document types drive what NSDocument can save and which class opens what: PNG/JPEG/HEIC/
TIFF/BMP/GIF/TGA/SGI/ICNS/JPEG 2000, PDF, Markdown, Rich text, Plain text = **Editor**; other images, Illustrator,
3D models and movies = Viewer; folders = Viewer with rank None (intercepted before any document is made). **Order
matters**: Illustrator sits before "Image" (`.ai` conforms to `public.image` and would open as a flat picture) and
3D models before "Plain text" (a `.usda` is text too).

## Decisions with a bug behind them (don't undo without reading the commit)

- **Window placement** centers the content, not the frame; `shouldCascadeWindows = false`, `isRestorable = false`.
  The view is pinned by constraints *after* the toolbar is attached (a copied frame went stale: images opened at 92%).
- **Markup bar** is added only while shown (`removeFromParent` when hidden): a hidden accessory still imposed its
  minimum width and pushed the next portrait video off center.
- **Undo** = whole-state snapshots in the document's undo manager. Synthetic events must go through
  `NSApp.postEvent`, or undo groups merge (a false "undo removes every mark" bug).
- **Text saving** keeps the file's encoding, BOM and dominant line ending (Return types LF, so CRLF files are
  normalised back to CRLF). If the encoding can't hold the text, UTF-8 is written and the toast says so.
  `breakUndoCoalescing()` runs at save, or typing after a save wouldn't mark the file edited.
- **Plain-text editor** has smart quotes, autocorrect, spell-check and link detection off: what you type is saved.
- **The text scroll bar never auto-hides.** With classic scroll bars, a bar toggling mid-layout changed the width,
  re-wrapped lines and looped forever (a 4 KB tqdm log hung Focal at 1.7 GB; 10/10 → 0/10). `TextViewTests` guards it.
  Sizing always reserves the legacy scroller width for the same reason.
- **Markdown** renders with apple/swift-cmark pinned at `exact: "0.9.0"` (GFM tables, task lists, autolinks,
  tagfilter, footnotes) into a WKWebView with **page JavaScript off**. The page is written to
  `$TMPDIR/FocalMarkdown/` and loaded with `loadFileURL(allowingReadAccessTo: "/")` plus a `<base href>`:
  `loadHTMLString` grants no file access, so relative images came up blank. Only clicked links navigate
  (no meta-refresh); `#anchor` links scroll in-page; local viewable files open in Focal. Pages are deleted on
  window close and at quit.
- **Markdown pages have WebKit's white base off** (`drawsBackground` through KVC, guarded: macOS has no public API). The
  first frames of a page are composited on opaque white before its CSS applies, so in dark mode 24 of 25 opens flashed
  white. Revealing the view later doesn't help (at `didFinish` 23 of 25, after a snapshot 21 of 25); with the base off, 0.
- **Rich text** zooms by `NSScrollView` magnification (text size ÷ 12 pt), never by rewriting the document's fonts,
  and sets the text view width by hand under magnification. Typing attributes start from the first character
  (else typing at the start came out Helvetica 12). ⌘B/⌘I/⌘U/⌘T are handled in `ZoomableTextView.performKeyEquivalent`:
  the key window's views see key equivalents before the menu bar, so these beat the app-wide ⌘I Inspector / ⌘T Trim.
- **Save As stays in the format family** (text ↔ Markdown, RTF ↔ RTFD) so a window never has to swap editors;
  `prepareSavePanel` allows any extension.
- **Multi-file opens are gathered in `FocalDocumentController.openDocument(withContentsOf:…)`**, one run-loop turn.
  AppKit sends Finder's "open documents" event straight to the document controller, one call per file;
  `AppDelegate.application(_:open:)` never sees them (three files opened three windows until this moved).
  Finder sends **one event per file type**, so a selection of texts and pictures opens one window per type. The
  user wants it that way (2026-11-07): a merge into one window was built (`ee35b07`) and reverted at their request.
- **Sidebar lightbox**: switching files doesn't resize the window (`sizedAsLightbox`); the sidebar widens the
  window to the left so the picture keeps its place; video aspect lock is off while browsing. Placement passes
  the real minimum width (the Markup bar's) minus the sidebar: without it small photos sat 164 pt off center.
- **Sidebar keeps the keyboard** while stepping (`sidebarKeepsFocus`; viewers check `mayTakeKeyboardFocus`),
  and its cells take the first click on a background window (the thumbnail image view had refused it).
- **Release and dev builds are separate apps** (name and bundle id): an identically named dev copy showed up as a
  duplicate "Focal" and shared the user's settings.
- **Edits made between events go through `InEvent`.** NSUndoManager closes its per-event group only after
  NSApplication dispatches an event, so a mark added from a dispatch block (or an out-of-process panel's
  completion) left the window unedited and Save grey until the next mouse move. PDF text marks need two hops:
  `DispatchQueue.main.async` (PDFKit's tracking loop pulled a straight-posted event out mid-drag, selection half
  made), then `InEvent.perform`.
- **PDF markup overlay** takes the mouse only for drawing tools or when a mark is under the pointer, so text
  selection, links and form fields stay PDFKit's. Starting a search clears the selection (a stale match was
  highlighted when the Highlight tool was picked). Redaction flattens those pages to pictures in the saved copy:
  a black box over live text would only hide it. Illustrator files are read-only (PDFKit would drop the AI data).
- **Multi-page saving** copies untouched pages from the file (`CGImageDestinationAddImageFromSource`, metadata kept)
  and redraws only edited ones; undo first returns to the page it changes. Animations can't be edited, so a Save As
  of an animated GIF copies its frames.
- **3D**: SceneKit "opens" a missing or broken file as an empty scene without error, so no geometry = an error
  message. glTF is converted with the system `usdcat` to `$TMPDIR/FocalModels/` (deleted on close and at quit).
  OpenVDB is not claimed (no public framework draws volumes). A stopped `NSProgressIndicator` stays drawn unless
  `isDisplayedWhenStopped = false`.

## Swift 6 patterns used here

- NSDocument overrides (`read`, `data(ofType:)`, `writableTypes`) are nonisolated: wrap the body in
  `MainActor.assumeIsolated` (this app never reads/writes concurrently). Non-Sendable results such as `FileWrapper`
  can't be returned from it; assign to a local instead.
- AVFoundation objects aren't Sendable: pass URLs into `nonisolated static` helpers.
- `NSTextFinderBarContainer` conformance needs `@preconcurrency`.
- `Notification` and `NSEvent` aren't Sendable: event-monitor bodies return a Bool from `MainActor.assumeIsolated`
  (never the event), and main-queue notifications cross in a small `@unchecked Sendable` box.

## UI testing (read before driving the app)

`scripts/uitest.sh` launches **Focal Dev** through Launch Services (`open -n -W -a`), with `FOCAL_UITEST=<json>`.
Steps run one after another, each with an optional `wait` in ms. Ops: `open action key(chars, code, mods) type click
drag scroll scrollText scrollVideo(dy, count, pixels) resize markup tool color dump snap(which: window|settings|inspector|sheet) contextMenu
clipboard export js saveAs saveTo revert terminate quit`, and for PDFs (`UITestDriver+PDF`) `pdfDrag pdfClick` (page
points, scrolled into view first) `search find goPage pages contents unlock endText setSignature sheetText`. `dump`
writes the window state as JSON: frame, title, subtitle, edited, toast, Save enabled, toolbar, text, zoom, pages,
annotations, PDF pages with their marks, 3D stats…

- A binary started from the terminal is never made active; always launch via `open`.
- Focal Dev's process is also named `Focal`: find it by path (`ps -axo pid=,comm=`), since `pgrep -x "Focal Dev"` matches nothing.
- The app never runs `screencapture` (it raised a Screen Recording prompt on the user's screen). `snap` hands the
  window id to the shell script, which takes the screenshot.
- The save panel runs **out of process**: `NSSavePanel.ok(_:)` throws "not implemented" and crashed a run (the user
  saw the crash dialog). Use `saveAs`; only photograph the sheet.
- Text inserted outside an event leaves the undo group open (document not "edited", Save disabled); `type` posts an
  event afterwards. A ⌘-key that "does nothing" mid-run is usually lost focus: the key op logs `active`/`key`.
- Timing-dependent bugs: force the suspected condition and compare hang rates over ~10 cold launches before and after.
  For a live hang: `/usr/bin/sample PID 2 -file out.txt` (a broken Python `sample` shim sits earlier on PATH);
  window titles via `CGWindowListCopyWindowInfo`; what the user opened, in order, from each file's
  `com.apple.lastuseddate#PS` xattr.
- Fixtures and scripts go in the session scratchpad, never in the repo or next to the user's files; check every
  fixture path exists first (a missing file raises an error alert that blocks the run).
- **Test opens through macOS too**, not only the driver's `open`/`openSet`: `open -n -a "build.noindex/Focal Dev.app"
  a b c` and count windows with `CGWindowListCopyWindowInfo` (owner name starts with "Focal"). The driver path
  hid the multi-file bug above.
- Synthetic clicks only land while Focal Dev is the key window; when the user is working in another app they are
  dropped (`sidebarClick` logs `key=`/`active=`). Repeat rather than conclude. **Keys need focus too; `action` doesn't**
  (it walks the window's responder chain), so prefer `action` for menu commands. Key `mods` are `command`,
  `shift`, `option`, `control` (not `cmd`).
- The user may have the installed Focal open: check before installing (`install.sh` now quits it gracefully).

## Known gaps

- MKV/WebM don't play (AVFoundation); a libmpv fallback was offered, not requested.
- A click on a background window's sidebar (first-mouse) is set up but can't be proven with synthetic events.
- Not yet exercised by a person or the harness: physical trackpad pinch, typing a name into the real Save panel,
  clicking each format-bar control, Find and Replace, full screen, Trim UI.
- Not decoded: MacPaint, FlashPix, fax (Preview lists them; no fixtures, no decoder). OpenVDB volumes. MaterialX
  node graphs beyond a shader's constant inputs and one base-colour image.
- Not yet exercised by a person: drawing in the signature sheet, dragging thumbnails to reorder PDF pages (the
  harness calls the move directly), dropping files on the page panel, PDF printing.
- The default-app buttons in Settings are for the user to click; don't run them.
