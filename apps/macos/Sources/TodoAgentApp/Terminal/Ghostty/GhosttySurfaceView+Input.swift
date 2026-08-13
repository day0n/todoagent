// Adapted from umputun/agterm and thdxg/macterm (MIT).

import AppKit
import GhosttyKit

extension GhosttySurfaceView {
    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        droppedText(from: sender.draggingPasteboard) == nil ? [] : .copy
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let text = droppedText(from: sender.draggingPasteboard) else { return false }
        DispatchQueue.main.async { [weak self] in self?.insertPasted(text) }
        return true
    }

    private func droppedText(from pasteboard: NSPasteboard) -> String? {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] {
            let escaped = urls.map { GhosttyShellEscape.argument($0.isFileURL ? $0.path(percentEncoded: false) : $0.absoluteString) }
            if !escaped.isEmpty { return escaped.joined(separator: " ") }
        }
        return pasteboard.string(forType: .string).flatMap { $0.isEmpty ? nil : $0 }
    }

    override func keyDown(with event: NSEvent) {
        guard let surface else { return super.keyDown(with: event) }
        let action: ghostty_input_action_e = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        if flags.contains(.control), !flags.contains(.command), !flags.contains(.option), !hasMarkedText() {
            var key = makeKeyEvent(event, action: action)
            let text = event.charactersIgnoringModifiers ?? event.characters ?? ""
            if text.isEmpty {
                _ = ghostty_surface_key(surface, key)
            } else {
                text.withCString { pointer in key.text = pointer; _ = ghostty_surface_key(surface, key) }
            }
            return
        }

        if flags.contains(.command) {
            var key = makeKeyEvent(event, action: action)
            key.text = nil
            _ = ghostty_surface_key(surface, key)
            return
        }

        let wasComposing = hasMarkedText()
        currentKeyEvent = event
        keyTextAccumulator = []
        let translated = translatedEvent(event)
        interpretKeyEvents([translated])
        currentKeyEvent = nil

        var key = makeKeyEvent(event, action: action)
        key.consumed_mods = consumedModifiers(translated.modifierFlags)
        key.composing = hasMarkedText() || wasComposing
        if !keyTextAccumulator.isEmpty {
            key.composing = false
            for text in keyTextAccumulator {
                text.withCString { pointer in key.text = pointer; _ = ghostty_surface_key(surface, key) }
            }
        } else if !hasMarkedText() {
            let text = printableText(event.characters ?? "")
            if !text.isEmpty, !key.composing {
                text.withCString { pointer in key.text = pointer; _ = ghostty_surface_key(surface, key) }
            } else {
                key.consumed_mods = GHOSTTY_MODS_NONE
                key.text = nil
                _ = ghostty_surface_key(surface, key)
            }
        }
    }

    override func keyUp(with event: NSEvent) {
        guard let surface else { return }
        var key = makeKeyEvent(event, action: GHOSTTY_ACTION_RELEASE)
        key.text = nil
        _ = ghostty_surface_key(surface, key)
    }

    override func flagsChanged(with event: NSEvent) {
        guard let surface else { return }
        var key = makeKeyEvent(event, action: isModifierPress(event) ? GHOSTTY_ACTION_PRESS : GHOSTTY_ACTION_RELEASE)
        key.text = nil
        _ = ghostty_surface_key(surface, key)
    }

    override func doCommand(by _: Selector) {}

    override func mouseDown(with event: NSEvent) { sendMouse(event, state: GHOSTTY_MOUSE_PRESS, button: GHOSTTY_MOUSE_LEFT, focus: true) }
    override func mouseUp(with event: NSEvent) { sendMouse(event, state: GHOSTTY_MOUSE_RELEASE, button: GHOSTTY_MOUSE_LEFT) }
    override func rightMouseDown(with event: NSEvent) { sendMouse(event, state: GHOSTTY_MOUSE_PRESS, button: GHOSTTY_MOUSE_RIGHT) }
    override func rightMouseUp(with event: NSEvent) { sendMouse(event, state: GHOSTTY_MOUSE_RELEASE, button: GHOSTTY_MOUSE_RIGHT) }
    override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2 else { return super.otherMouseDown(with: event) }
        sendMouse(event, state: GHOSTTY_MOUSE_PRESS, button: GHOSTTY_MOUSE_MIDDLE)
    }
    override func otherMouseUp(with event: NSEvent) {
        guard event.buttonNumber == 2 else { return super.otherMouseUp(with: event) }
        sendMouse(event, state: GHOSTTY_MOUSE_RELEASE, button: GHOSTTY_MOUSE_MIDDLE)
    }

    override func scrollWheel(with event: NSEvent) {
        guard let surface else { return }
        reportMousePosition(event)
        var scrollModifiers: ghostty_input_scroll_mods_t = 0
        if event.hasPreciseScrollingDeltas { scrollModifiers |= 1 }
        ghostty_surface_mouse_scroll(surface, event.scrollingDeltaX, event.scrollingDeltaY, scrollModifiers)
    }

    func reportMousePosition(_ event: NSEvent) {
        guard let surface else { return }
        let point = convert(event.locationInWindow, from: nil)
        ghostty_surface_mouse_pos(surface, point.x, bounds.height - point.y, inputModifiers(event))
    }

    private func sendMouse(
        _ event: NSEvent,
        state: ghostty_input_mouse_state_e,
        button: ghostty_input_mouse_button_e,
        focus: Bool = false
    ) {
        guard let surface else { return }
        if focus { window?.makeFirstResponder(self); updateGhosttyFocus() }
        reportMousePosition(event)
        _ = ghostty_surface_mouse_button(surface, state, button, inputModifiers(event))
    }

    func inputModifiers(_ event: NSEvent) -> ghostty_input_mods_e {
        var value = GHOSTTY_MODS_NONE.rawValue
        let flags = event.modifierFlags
        if flags.contains(.shift) { value |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.control) { value |= GHOSTTY_MODS_CTRL.rawValue }
        if flags.contains(.option) { value |= GHOSTTY_MODS_ALT.rawValue }
        if flags.contains(.command) { value |= GHOSTTY_MODS_SUPER.rawValue }
        if flags.contains(.capsLock) { value |= GHOSTTY_MODS_CAPS.rawValue }
        return ghostty_input_mods_e(rawValue: value)
    }

    private func makeKeyEvent(_ event: NSEvent, action: ghostty_input_action_e) -> ghostty_input_key_s {
        var key = ghostty_input_key_s()
        key.action = action
        key.keycode = UInt32(event.keyCode)
        key.mods = inputModifiers(event)
        key.consumed_mods = GHOSTTY_MODS_NONE
        key.composing = false
        key.unshifted_codepoint = unshiftedCodepoint(event)
        return key
    }

    private func consumedModifiers(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var value = GHOSTTY_MODS_NONE.rawValue
        if flags.contains(.shift) { value |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.option) { value |= GHOSTTY_MODS_ALT.rawValue }
        if flags.contains(.capsLock) { value |= GHOSTTY_MODS_CAPS.rawValue }
        return ghostty_input_mods_e(rawValue: value)
    }

    private func isModifierPress(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 56, 60: event.modifierFlags.contains(.shift)
        case 58, 61: event.modifierFlags.contains(.option)
        case 59, 62: event.modifierFlags.contains(.control)
        case 55, 54: event.modifierFlags.contains(.command)
        case 57: event.modifierFlags.contains(.capsLock)
        default: false
        }
    }

    private func printableText(_ text: String) -> String {
        guard let scalar = text.unicodeScalars.first else { return "" }
        return scalar.value < 0x20 || (0xF700 ... 0xF8FF).contains(scalar.value) ? "" : text
    }

    private func translatedEvent(_ event: NSEvent) -> NSEvent {
        guard let surface else { return event }
        let translatedRaw = ghostty_surface_key_translation_mods(surface, inputModifiers(event)).rawValue
        var flags = event.modifierFlags
        for (bit, flag) in [
            (GHOSTTY_MODS_SHIFT.rawValue, NSEvent.ModifierFlags.shift),
            (GHOSTTY_MODS_CTRL.rawValue, .control),
            (GHOSTTY_MODS_ALT.rawValue, .option),
            (GHOSTTY_MODS_SUPER.rawValue, .command),
        ] {
            if translatedRaw & bit == 0 {
                flags.remove(flag)
            } else {
                flags.insert(flag)
            }
        }
        guard flags != event.modifierFlags else { return event }
        return NSEvent.keyEvent(
            with: event.type,
            location: event.locationInWindow,
            modifierFlags: flags,
            timestamp: event.timestamp,
            windowNumber: event.windowNumber,
            context: nil,
            characters: event.characters(byApplyingModifiers: flags) ?? "",
            charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
            isARepeat: event.isARepeat,
            keyCode: event.keyCode
        ) ?? event
    }

    private func unshiftedCodepoint(_ event: NSEvent) -> UInt32 {
        guard event.type == .keyDown || event.type == .keyUp,
              let scalar = event.characters(byApplyingModifiers: [])?.unicodeScalars.first
        else { return 0 }
        return scalar.value
    }
}

extension GhosttySurfaceView: @preconcurrency NSTextInputClient {
    func insertText(_ string: Any, replacementRange _: NSRange) {
        guard !committingComposition else { return }
        let text = (string as? String) ?? (string as? NSAttributedString)?.string ?? ""
        guard !text.isEmpty else { return }
        markedTextRange = NSRange(location: NSNotFound, length: 0)
        markedTextValue = ""
        if let surface { ghostty_surface_preedit(surface, nil, 0) }
        if currentKeyEvent != nil {
            keyTextAccumulator.append(text)
        } else if let surface {
            text.withCString { pointer in
                var key = ghostty_input_key_s()
                key.action = GHOSTTY_ACTION_PRESS
                key.text = pointer
                _ = ghostty_surface_key(surface, key)
            }
        }
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange _: NSRange) {
        guard let surface else { return }
        let text = (string as? String) ?? (string as? NSAttributedString)?.string ?? ""
        markedTextRange = text.isEmpty ? NSRange(location: NSNotFound, length: 0) : NSRange(location: 0, length: text.utf16.count)
        markedTextValue = text
        selectedTextRange = selectedRange
        text.withCString { ghostty_surface_preedit(surface, $0, UInt(text.utf8.count)) }
    }

    func unmarkText() {
        markedTextRange = NSRange(location: NSNotFound, length: 0)
        markedTextValue = ""
        if let surface { ghostty_surface_preedit(surface, nil, 0) }
    }

    func selectedRange() -> NSRange { selectedTextRange }
    func markedRange() -> NSRange { markedTextRange }
    func hasMarkedText() -> Bool { markedTextRange.location != NSNotFound }

    func commitComposition() {
        guard hasMarkedText() else { return }
        if markedTextValue.isEmpty { unmarkText() }
        else { insertText(markedTextValue, replacementRange: NSRange(location: NSNotFound, length: 0)) }
        guard window?.firstResponder === self else { return }
        committingComposition = true
        inputContext?.discardMarkedText()
        committingComposition = false
    }

    func insertPasted(_ text: String) {
        guard !text.isEmpty, let surface else { return }
        commitComposition()
        text.withCString { ghostty_surface_text(surface, $0, UInt(text.utf8.count)) }
    }

    func attributedSubstring(forProposedRange _: NSRange, actualRange _: NSRangePointer?) -> NSAttributedString? { nil }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [.underlineStyle, .backgroundColor] }
    func characterIndex(for _: NSPoint) -> Int { NSNotFound }
    func firstRect(forCharacterRange _: NSRange, actualRange _: NSRangePointer?) -> NSRect {
        guard let surface else { return .zero }
        var x = 0.0, y = 0.0, width = 0.0, height = 0.0
        ghostty_surface_ime_point(surface, &x, &y, &width, &height)
        let local = NSPoint(x: x, y: bounds.height - y)
        let screen = window?.convertPoint(toScreen: convert(local, to: nil)) ?? local
        return NSRect(x: screen.x, y: screen.y - height, width: width, height: height)
    }
}

extension GhosttySurfaceView: NSMenuItemValidation {
    @objc func copy(_ sender: Any?) { performBinding("copy_to_clipboard") }
    @objc func paste(_ sender: Any?) { performBinding("paste_from_clipboard") }
    override func selectAll(_ sender: Any?) { performBinding("select_all") }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let surface else { return false }
        if menuItem.action == #selector(copy(_:)) { return ghostty_surface_has_selection(surface) }
        if menuItem.action == #selector(paste(_:)) { return NSPasteboard.general.string(forType: .string) != nil }
        return menuItem.action == #selector(selectAll(_:))
    }

    func performBinding(_ action: String) {
        guard let surface else { return }
        action.withCString { _ = ghostty_surface_binding_action(surface, $0, UInt(action.utf8.count)) }
    }

    @objc func performFindPanelAction(_ sender: Any?) {
        let rawAction = (sender as? NSNumber)?.uintValue ?? NSFindPanelAction.showFindPanel.rawValue
        switch NSFindPanelAction(rawValue: rawAction) {
        case .showFindPanel:
            performBinding("start_search")
        case .next:
            performBinding("navigate_search:previous")
        case .previous:
            performBinding("navigate_search:next")
        case .setFindString:
            if let needle = NSPasteboard(name: .find).string(forType: .string), !needle.isEmpty {
                performBinding("search:\(needle)")
            }
        default:
            break
        }
    }
}

enum GhosttyShellEscape {
    static func argument(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
