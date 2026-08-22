import AppKit
import Testing
@testable import TodoAgentApp

@Suite("Window input focus dismissal")
struct WindowInputFocusMonitorTests {
    @MainActor
    @Test("clicking a non-input region ends the active text edit")
    func nonInputClickDismissesFocus() throws {
        let fixture = makeFixture()
        try #require(fixture.window.makeFirstResponder(fixture.textField))
        let originalResponder = fixture.window.firstResponder

        let dismissed = WindowInputFocusDismissal.dismissEditing(
            in: fixture.window,
            clickedView: fixture.background
        )

        #expect(dismissed)
        #expect(fixture.window.firstResponder !== originalResponder)
        #expect(fixture.window.firstResponder === fixture.window)
    }

    @MainActor
    @Test("clicking an input preserves editing so AppKit can transfer focus")
    func inputClickPreservesFocus() throws {
        let fixture = makeFixture()
        try #require(fixture.window.makeFirstResponder(fixture.textField))
        let originalResponder = fixture.window.firstResponder

        let dismissed = WindowInputFocusDismissal.dismissEditing(
            in: fixture.window,
            clickedView: fixture.textField
        )

        #expect(!dismissed)
        #expect(fixture.window.firstResponder === originalResponder)
    }

    @MainActor
    @Test("an editable text view and its scroll container remain input targets")
    func textEditorContainerPreservesFocus() {
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 220, height: 120))
        let textView = NSTextView(frame: scrollView.bounds)
        textView.isEditable = true
        scrollView.documentView = textView

        #expect(WindowInputFocusDismissal.isTextInputTarget(textView))
        #expect(WindowInputFocusDismissal.isTextInputTarget(scrollView.contentView))
        #expect(WindowInputFocusDismissal.isTextInputTarget(scrollView))
    }

    @MainActor
    @Test("task detail commit ends only its own popover editor")
    func taskDetailCommitIsWindowScoped() throws {
        let firstTextView = TaskNoteTextView(frame: NSRect(x: 0, y: 0, width: 180, height: 80))
        let firstWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 220, height: 120),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        firstWindow.contentView = firstTextView
        try #require(firstWindow.makeFirstResponder(firstTextView))

        let secondTextView = TaskNoteTextView(frame: NSRect(x: 0, y: 0, width: 180, height: 80))
        let secondWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 220, height: 120),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        secondWindow.contentView = secondTextView
        try #require(secondWindow.makeFirstResponder(secondTextView))

        TaskDetailTextInputCommitter.commitEditing(in: firstWindow)

        #expect(firstWindow.firstResponder !== firstTextView)
        #expect(secondWindow.firstResponder === secondTextView)
    }

    @MainActor
    private func makeFixture() -> (
        window: NSWindow,
        background: NSView,
        textField: NSTextField
    ) {
        let background = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 180))
        let textField = NSTextField(frame: NSRect(x: 20, y: 120, width: 180, height: 24))
        background.addSubview(textField)

        let window = NSWindow(
            contentRect: background.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = background
        return (window, background, textField)
    }
}
