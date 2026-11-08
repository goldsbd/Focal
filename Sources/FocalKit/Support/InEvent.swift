import AppKit

/// Runs work as part of an event, not between events. NSUndoManager closes its per-event group only after
/// NSApplication dispatches an event, so an edit made from a dispatch-queue block or an out-of-process panel's
/// completion left the group open: the window didn't show edited and Save stayed grey until the next mouse move.
/// Posting an application-defined event and doing the work when it arrives keeps every edit one closed undo step.
@MainActor
enum InEvent {
    private static let subtype: Int16 = 0x464F   // "FO"
    private static var pending: [Int: () -> Void] = [:]
    private static var next = 0
    private static var monitor: Any?

    static func perform(in window: NSWindow?, _ body: @escaping () -> Void) {
        if monitor == nil {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .applicationDefined) { event in
                guard event.subtype.rawValue == subtype else { return event }
                MainActor.assumeIsolated { pending.removeValue(forKey: event.data1)?() }
                return nil
            }
        }
        next += 1
        pending[next] = body
        guard let event = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0,
                                             windowNumber: window?.windowNumber ?? 0, context: nil, subtype: subtype,
                                             data1: next, data2: 0) else {
            pending.removeValue(forKey: next)?()
            return
        }
        NSApp.postEvent(event, atStart: false)   // after the events already queued (the mouse-up PDFKit is finishing)
    }
}
