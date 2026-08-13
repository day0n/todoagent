// Adapted from umputun/agterm's Ghostty search bridge (MIT).

import AppKit

extension GhosttySurfaceView {
    func showFindBar(initialNeedle: String) {
        if let findBar {
            if !initialNeedle.isEmpty { findBar.setNeedle(initialNeedle) }
            findBar.focusField()
            return
        }
        let bar = GhosttyFindBarView()
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.onNeedleChanged = { [weak self] needle in self?.performBinding("search:\(needle)") }
        bar.onNext = { [weak self] in self?.performBinding("navigate_search:previous") }
        bar.onPrevious = { [weak self] in self?.performBinding("navigate_search:next") }
        bar.onClose = { [weak self] in self?.performBinding("end_search") }
        addSubview(bar)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            bar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            bar.widthAnchor.constraint(greaterThanOrEqualToConstant: 330),
        ])
        findBar = bar
        bar.setNeedle(initialNeedle)
        bar.focusField()
    }

    func hideFindBar() {
        findBar?.removeFromSuperview()
        findBar = nil
        if let window { window.makeFirstResponder(self) }
        updateGhosttyFocus()
    }

    func updateFindCount(total: Int) {
        findTotal = max(0, total)
        updateFindCounter()
    }

    func updateFindSelection(selected: Int) {
        findSelected = selected
        updateFindCounter()
    }

    private func updateFindCounter() {
        let label: String
        if findTotal <= 0 {
            label = "0 matches"
        } else {
            let oneBased = min(max(findSelected + 1, 1), findTotal)
            label = "\(oneBased) of \(findTotal)"
        }
        findBar?.setCounter(label)
    }
}

@MainActor
final class GhosttyFindBarView: NSVisualEffectView, NSSearchFieldDelegate {
    var onNeedleChanged: ((String) -> Void)?
    var onNext: (() -> Void)?
    var onPrevious: (() -> Void)?
    var onClose: (() -> Void)?

    private let field = NSSearchField()
    private let counter = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .popover
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 8

        field.placeholderString = "Find"
        field.delegate = self
        counter.textColor = .secondaryLabelColor
        counter.alignment = .right

        let previous = button(symbol: "chevron.up", action: #selector(previousMatch))
        let next = button(symbol: "chevron.down", action: #selector(nextMatch))
        let close = button(symbol: "xmark", action: #selector(closeFind))
        let stack = NSStackView(views: [field, counter, previous, next, close])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 7
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            field.widthAnchor.constraint(greaterThanOrEqualToConstant: 160),
            counter.widthAnchor.constraint(greaterThanOrEqualToConstant: 65),
        ])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("init(coder:) is not supported") }

    func setNeedle(_ value: String) {
        guard field.stringValue != value else { return }
        field.stringValue = value
        if !value.isEmpty { onNeedleChanged?(value) }
    }

    func setCounter(_ value: String) { counter.stringValue = value }
    func focusField() { window?.makeFirstResponder(field) }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { focusField() }
    }

    func controlTextDidChange(_ notification: Notification) {
        guard notification.object as AnyObject? === field else { return }
        onNeedleChanged?(field.stringValue)
    }

    func control(_ control: NSControl, textView _: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard control === field else { return false }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            NSEvent.modifierFlags.contains(.shift) ? onPrevious?() : onNext?()
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            onClose?()
            return true
        }
        return false
    }

    private func button(symbol: String, action: Selector) -> NSButton {
        let result = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage(),
                              target: self, action: action)
        result.isBordered = false
        result.imageScaling = .scaleProportionallyDown
        return result
    }

    @objc private func previousMatch() { onPrevious?() }
    @objc private func nextMatch() { onNext?() }
    @objc private func closeFind() { onClose?() }
}
