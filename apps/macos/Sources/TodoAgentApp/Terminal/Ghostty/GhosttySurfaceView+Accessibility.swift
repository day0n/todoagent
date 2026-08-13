// Read-side accessibility is adapted from Ghostty's native AppKit surface;
// write routing follows agterm's minimal editable-terminal bridge (MIT).

import AppKit
import CoreText
import GhosttyKit

extension GhosttySurfaceView {
    private var accessibilityExposed: Bool {
        surface != nil && window?.isVisible == true && window?.isMiniaturized == false
    }

    private var accessibilityFocused: Bool {
        accessibilityExposed && window?.isKeyWindow == true && window?.firstResponder === self
    }

    override func isAccessibilityElement() -> Bool { accessibilityExposed }
    override func accessibilityRole() -> NSAccessibility.Role? {
        accessibilityExposed ? .textArea : super.accessibilityRole()
    }
    override func accessibilityLabel() -> String? {
        accessibilityExposed ? "Terminal" : super.accessibilityLabel()
    }
    override func accessibilityHelp() -> String? {
        accessibilityExposed ? "Terminal content area" : super.accessibilityHelp()
    }
    override func isAccessibilityFocused() -> Bool {
        accessibilityExposed ? accessibilityFocused : super.isAccessibilityFocused()
    }

    override func accessibilityValue() -> Any? {
        accessibilityExposed ? accessibilityScreenText() : super.accessibilityValue()
    }

    override func accessibilityNumberOfCharacters() -> Int {
        accessibilityExposed ? accessibilityScreenText().utf16.count : super.accessibilityNumberOfCharacters()
    }

    override func accessibilityVisibleCharacterRange() -> NSRange {
        guard accessibilityExposed else { return super.accessibilityVisibleCharacterRange() }
        return NSRange(location: 0, length: accessibilityScreenText().utf16.count)
    }

    override func accessibilitySelectedText() -> String? {
        guard accessibilityExposed, let surface, ghostty_surface_has_selection(surface) else {
            return accessibilityExposed ? nil : super.accessibilitySelectedText()
        }
        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }
        guard let bytes = text.text, text.text_len > 0 else { return nil }
        return String(decoding: UnsafeRawBufferPointer(start: bytes, count: Int(text.text_len)), as: UTF8.self)
    }

    override func accessibilitySelectedTextRange() -> NSRange {
        guard accessibilityExposed else { return super.accessibilitySelectedTextRange() }
        let value = accessibilityScreenText() as NSString
        guard let selected = accessibilitySelectedText(), !selected.isEmpty else {
            return NSRange(location: value.length, length: 0)
        }
        let range = value.range(of: selected, options: .backwards)
        return range.location == NSNotFound ? NSRange(location: value.length, length: 0) : range
    }

    override func accessibilityLine(for index: Int) -> Int {
        guard accessibilityExposed else { return super.accessibilityLine(for: index) }
        let value = accessibilityScreenText() as NSString
        let bounded = min(max(index, 0), value.length)
        return value.substring(to: bounded).components(separatedBy: .newlines).count - 1
    }

    override func accessibilityString(for range: NSRange) -> String? {
        guard accessibilityExposed else { return super.accessibilityString(for: range) }
        let value = accessibilityScreenText() as NSString
        guard range.location != NSNotFound,
              range.location <= value.length,
              range.length <= value.length - range.location
        else { return nil }
        return value.substring(with: range)
    }

    override func accessibilityAttributedString(for range: NSRange) -> NSAttributedString? {
        guard let plain = accessibilityString(for: range) else { return nil }
        guard let surface, let rawFont = ghostty_surface_quicklook_font(surface) else {
            return NSAttributedString(string: plain)
        }
        let font = Unmanaged<CTFont>.fromOpaque(rawFont).takeUnretainedValue()
        return NSAttributedString(string: plain, attributes: [.font: font])
    }

    override func setAccessibilityValue(_ value: Any?) {
        guard accessibilityFocused else { return }
        let text = (value as? String) ?? (value as? NSAttributedString)?.string ?? ""
        guard !text.isEmpty else { return }
        insertAccessibilityText(text)
    }

    override func setAccessibilitySelectedText(_ value: String?) {
        guard accessibilityFocused, let value, !value.isEmpty else { return }
        insertAccessibilityText(value)
    }

    override func isAccessibilitySelectorAllowed(_ selector: Selector) -> Bool {
        if selector == #selector(setAccessibilityValue(_:)) || selector == #selector(setAccessibilitySelectedText(_:)) {
            return accessibilityExposed && window?.firstResponder === self
        }
        return super.isAccessibilitySelectorAllowed(selector)
    }

    func accessibilityExposureDidChange() {
        let exposed = accessibilityExposed
        guard exposed != accessibilityExposurePosted else { return }
        accessibilityExposurePosted = exposed
        let element: NSResponder = window ?? NSApplication.shared
        NSAccessibility.post(element: element, notification: .layoutChanged, userInfo: [.uiElements: [self]])
    }

    func accessibilityFocusDidChange() {
        guard !accessibilityFocusPostScheduled else { return }
        accessibilityFocusPostScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.accessibilityFocusPostScheduled = false
            let focused = self.accessibilityFocused
            guard focused != self.accessibilityFocusPosted else { return }
            self.accessibilityFocusPosted = focused
            NSAccessibility.post(element: NSApplication.shared, notification: .focusedUIElementChanged)
            if let window = self.window {
                NSAccessibility.post(element: window, notification: .focusedUIElementChanged)
            }
        }
    }

    private func accessibilityScreenText() -> String {
        let now = ProcessInfo.processInfo.systemUptime
        if let cache = accessibilityTextCache, now - cache.timestamp < 0.5 { return cache.value }
        guard let surface else { return "" }
        var selection = ghostty_selection_s()
        selection.top_left = ghostty_point_s(
            tag: GHOSTTY_POINT_VIEWPORT,
            coord: GHOSTTY_POINT_COORD_TOP_LEFT,
            x: 0,
            y: 0
        )
        selection.bottom_right = ghostty_point_s(
            tag: GHOSTTY_POINT_VIEWPORT,
            coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT,
            x: 0,
            y: 0
        )
        selection.rectangle = false
        var text = ghostty_text_s()
        guard ghostty_surface_read_text(surface, selection, &text) else { return "" }
        defer { ghostty_surface_free_text(surface, &text) }
        let value: String
        if let bytes = text.text, text.text_len > 0 {
            value = String(decoding: UnsafeRawBufferPointer(start: bytes, count: Int(text.text_len)), as: UTF8.self)
        } else {
            value = ""
        }
        accessibilityTextCache = (value, now)
        return value
    }

    private func insertAccessibilityText(_ text: String) {
        let needsPaste = text.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F }
        if needsPaste {
            insertPasted(text)
        } else {
            commitComposition()
            insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
        }
    }
}
