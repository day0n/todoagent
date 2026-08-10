import AppKit

/// Applies the standard macOS editor behavior consistently across SwiftUI
/// screens: clicking another editor transfers focus naturally, while clicking
/// any non-editing region ends the current text edit.
@MainActor
final class WindowInputFocusMonitor {
    private var eventMonitor: Any?

    func start() {
        guard eventMonitor == nil else { return }

        eventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { event in
            WindowInputFocusDismissal.handleMouseDown(event)
            return event
        }
    }

    func stop() {
        guard let eventMonitor else { return }
        NSEvent.removeMonitor(eventMonitor)
        self.eventMonitor = nil
    }
}

@MainActor
enum WindowInputFocusDismissal {
    static func handleMouseDown(_ event: NSEvent) {
        let eventWindow = event.window
        let focusedWindow = NSApp.keyWindow ?? eventWindow

        guard let focusedWindow else { return }

        // When another TodoAgent window or menu is clicked, finish editing in
        // the previously focused window before AppKit transfers key status.
        guard focusedWindow === eventWindow else {
            dismissEditing(in: focusedWindow, clickedView: nil)
            return
        }

        dismissEditing(
            in: focusedWindow,
            clickedView: hitView(for: event, in: focusedWindow)
        )
    }

    @discardableResult
    static func dismissEditing(in window: NSWindow, clickedView: NSView?) -> Bool {
        guard isEditableTextResponder(window.firstResponder),
              !isTextInputTarget(clickedView)
        else { return false }

        return window.makeFirstResponder(nil)
    }

    static func isTextInputTarget(_ view: NSView?) -> Bool {
        var candidate = view

        while let current = candidate {
            if current is NSTextField {
                return true
            }

            if let textView = current as? NSTextView, textView.isEditable {
                return true
            }

            if let scrollView = current as? NSScrollView,
               let textView = scrollView.documentView as? NSTextView,
               textView.isEditable
            {
                return true
            }

            candidate = current.superview
        }

        return false
    }

    private static func isEditableTextResponder(_ responder: NSResponder?) -> Bool {
        if responder is NSTextField {
            return true
        }

        guard let textView = responder as? NSTextView else { return false }
        return textView.isEditable
    }

    private static func hitView(for event: NSEvent, in window: NSWindow) -> NSView? {
        guard let contentView = window.contentView else { return nil }
        let location = contentView.convert(event.locationInWindow, from: nil)
        return contentView.hitTest(location)
    }
}
