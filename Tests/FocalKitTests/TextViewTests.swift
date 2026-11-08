import AppKit
import Testing
@testable import FocalKit

/// An auto-hiding scroll bar made AppKit loop forever inside one layout pass (bar appears → text narrows →
/// lines re-wrap → height changes → bar hides …): a 4 KB tqdm log hung Focal at 100% CPU and 1.7 GB.
/// Reproduced 10/10 with classic scroll bars before the fix, 0/10 after. Keep the bar fixed.
@MainActor @Test func textScrollBarNeverAutoHides() throws {
    for type in ["public.plain-text", "public.rtf"] {
        let doc = TextDocument()
        try doc.read(from: Data("line\n".utf8), ofType: "public.plain-text")
        doc.fileType = type
        let controller = TextViewController(document: doc)
        _ = controller.view
        #expect(controller.scrollView.autohidesScrollers == false, "\(type)")
    }
}
