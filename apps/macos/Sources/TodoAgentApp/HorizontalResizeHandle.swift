import AppKit
import SwiftUI

@MainActor
enum HorizontalResizeCursorOwnership {
    private static weak var owner: HorizontalResizeHandleView?
    private static weak var ownerWindow: NSWindow?

    static func claim(_ view: HorizontalResizeHandleView) {
        owner = view
        ownerWindow = view.window
    }

    static func release(_ view: HorizontalResizeHandleView) {
        guard owner === view else { return }
        owner = nil
        ownerWindow = nil
    }

    static func ownsCursor(in window: NSWindow?) -> Bool {
        guard let owner else {
            ownerWindow = nil
            return false
        }
        guard let window,
              ownerWindow === window,
              owner.window === window
        else {
            // A cursor update from another app window must not revoke the
            // active resize taking place in the owner's window.
            return false
        }
        guard owner.canOwnResizeCursor(in: window) else {
            release(owner)
            return false
        }
        return true
    }
}

/// A native resize target whose cursor rect and drag tracking cover the exact
/// same bounds.
///
/// SwiftUI hover state only fires when the pointer crosses a boundary. That is
/// not sufficient beside Ghostty because the embedded AppKit surface can reset
/// the cursor while the pointer remains over a SwiftUI divider. Tracking the
/// complete interaction in one NSView keeps hit testing, cursor ownership, and
/// drag translation in sync.
@MainActor
struct HorizontalResizeHandle: NSViewRepresentable {
    var isEnabled = true
    let onDragChanged: (CGFloat) -> Void
    let onDragEnded: (CGFloat) -> Void

    func makeNSView(context _: Context) -> HorizontalResizeHandleView {
        let view = HorizontalResizeHandleView()
        configure(view)
        return view
    }

    func updateNSView(_ nsView: HorizontalResizeHandleView, context _: Context) {
        configure(nsView)
    }

    static func dismantleNSView(_ nsView: HorizontalResizeHandleView, coordinator _: ()) {
        nsView.finishActiveDrag(deferred: true)
        nsView.prepareForDismantle()
    }

    private func configure(_ view: HorizontalResizeHandleView) {
        // Disabling can finish an in-flight drag. Do that before installing
        // the next SwiftUI render's closures so an old interaction cannot be
        // committed against a new task or geometry snapshot.
        view.isInteractionEnabled = isEnabled
        view.onDragChanged = onDragChanged
        view.onDragEnded = onDragEnded
    }
}

@MainActor
final class HorizontalResizeHandleView: NSView {
    var onDragChanged: (CGFloat) -> Void = { _ in }
    var onDragEnded: (CGFloat) -> Void = { _ in }

    var isInteractionEnabled = true {
        didSet {
            guard isInteractionEnabled != oldValue else { return }
            if !isInteractionEnabled {
                // A representable is commonly disabled from updateNSView.
                // Defer the SwiftUI state callback until reconciliation has
                // returned, while clearing the native baseline immediately.
                finishActiveDrag(deferred: true)
                HorizontalResizeCursorOwnership.release(self)
            }
            invalidateCursorRects()
        }
    }

    private(set) var dragOriginInWindow: CGFloat?
    private(set) var latestTranslation: CGFloat = 0
    private var trackingAreaToken: NSTrackingArea?
    nonisolated(unsafe) private var lifecycleObserverTokens: [NSObjectProtocol] = []

    deinit {
        lifecycleObserverTokens.forEach(NotificationCenter.default.removeObserver)
    }

    override func acceptsFirstMouse(for _: NSEvent?) -> Bool {
        isInteractionEnabled
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard isInteractionEnabled, bounds.contains(point) else { return nil }
        return self
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard isInteractionEnabled else { return }
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaToken {
            removeTrackingArea(trackingAreaToken)
        }
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [
                .mouseEnteredAndExited,
                .cursorUpdate,
                .activeInKeyWindow,
                .inVisibleRect,
                .enabledDuringMouseDrag,
            ],
            owner: self
        )
        addTrackingArea(trackingArea)
        trackingAreaToken = trackingArea
    }

    override func cursorUpdate(with _: NSEvent) {
        guard isInteractionEnabled else { return }
        HorizontalResizeCursorOwnership.claim(self)
        NSCursor.resizeLeftRight.set()
    }

    override func mouseEntered(with _: NSEvent) {
        guard isInteractionEnabled else { return }
        HorizontalResizeCursorOwnership.claim(self)
        NSCursor.resizeLeftRight.set()
    }

    override func mouseExited(with _: NSEvent) {
        guard dragOriginInWindow == nil else {
            NSCursor.resizeLeftRight.set()
            return
        }
        HorizontalResizeCursorOwnership.release(self)
    }

    override func mouseDown(with event: NSEvent) {
        guard isInteractionEnabled else { return }
        dragOriginInWindow = event.locationInWindow.x
        latestTranslation = 0
        HorizontalResizeCursorOwnership.claim(self)
        NSCursor.resizeLeftRight.set()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragOriginInWindow, isInteractionEnabled else { return }
        latestTranslation = event.locationInWindow.x - dragOriginInWindow
        HorizontalResizeCursorOwnership.claim(self)
        NSCursor.resizeLeftRight.set()
        onDragChanged(latestTranslation)
    }

    override func mouseUp(with event: NSEvent) {
        guard let dragOriginInWindow else { return }
        latestTranslation = event.locationInWindow.x - dragOriginInWindow
        finishActiveDrag()
        updateCursor(for: event)
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if window !== newWindow {
            finishActiveDrag(deferred: true)
            HorizontalResizeCursorOwnership.release(self)
            stopObservingLifecycle()
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observeLifecycle(in: window)
    }

    func finishActiveDrag(deferred: Bool = false) {
        guard dragOriginInWindow != nil else { return }
        let finalTranslation = latestTranslation
        let completion = onDragEnded
        dragOriginInWindow = nil
        latestTranslation = 0
        if deferred {
            Task { @MainActor in
                await Task.yield()
                completion(finalTranslation)
            }
        } else {
            completion(finalTranslation)
        }
    }

    func prepareForDismantle() {
        HorizontalResizeCursorOwnership.release(self)
        stopObservingLifecycle()
    }

    func canOwnResizeCursor(in candidateWindow: NSWindow) -> Bool {
        guard isInteractionEnabled, window === candidateWindow else { return false }
        if dragOriginInWindow != nil { return true }
        let localPoint = convert(candidateWindow.mouseLocationOutsideOfEventStream, from: nil)
        return bounds.contains(localPoint)
    }

    private func invalidateCursorRects() {
        window?.invalidateCursorRects(for: self)
    }

    private func updateCursor(for event: NSEvent) {
        let localPoint = convert(event.locationInWindow, from: nil)
        if isInteractionEnabled && bounds.contains(localPoint) {
            HorizontalResizeCursorOwnership.claim(self)
            NSCursor.resizeLeftRight.set()
        } else {
            HorizontalResizeCursorOwnership.release(self)
            NSCursor.arrow.set()
        }
        invalidateCursorRects()
    }

    private func observeLifecycle(in window: NSWindow?) {
        stopObservingLifecycle()
        guard let window else { return }
        let center = NotificationCenter.default
        for name in [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification] {
            lifecycleObserverTokens.append(center.addObserver(
                forName: name,
                object: window,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.finishInterruptedDrag()
                }
            })
        }
        lifecycleObserverTokens.append(center.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: NSApp,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.finishInterruptedDrag()
            }
        })
    }

    private func stopObservingLifecycle() {
        lifecycleObserverTokens.forEach(NotificationCenter.default.removeObserver)
        lifecycleObserverTokens.removeAll()
    }

    private func finishInterruptedDrag() {
        finishActiveDrag(deferred: true)
        HorizontalResizeCursorOwnership.release(self)
        invalidateCursorRects()
    }
}
