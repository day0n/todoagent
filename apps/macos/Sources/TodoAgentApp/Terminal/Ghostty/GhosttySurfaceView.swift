// Adapted from umputun/agterm and thdxg/macterm (MIT).

import AppKit
import GhosttyKit
import QuartzCore

/// One stable AppKit host for one Ghostty PTY surface.
@MainActor
final class GhosttySurfaceView: NSView {
    nonisolated(unsafe) private(set) var surface: ghostty_surface_t?

    private let app: ghostty_app_t
    private let configuration: GhosttyTerminalConfiguration
    nonisolated(unsafe) private var configStrings: [UnsafeMutablePointer<CChar>] = []
    nonisolated(unsafe) private var environment: [ghostty_env_var_s] = []
    nonisolated(unsafe) private var observerTokens: [NSObjectProtocol] = []
    private var pendingCreation = false
    private var destroyed = false
    private var reportedExit = false
    private var trackingAreaToken: NSTrackingArea?
    private var mouseShape: ghostty_action_mouse_shape_e = GHOSTTY_MOUSE_SHAPE_TEXT
    private var pointerInside = false
    private var reportedVisibility: Bool?
    private var screensAsleep = false
    private var pendingRefresh = false
    private var wakeRetryCount = 0
    private var lastDisplayID: UInt32?
    var accessibilityTextCache: (value: String, timestamp: TimeInterval)?
    var accessibilityExposurePosted = false
    var accessibilityFocusPosted = false
    var accessibilityFocusPostScheduled = false
    var findBar: GhosttyFindBarView?
    var findTotal = 0
    var findSelected = -1

    var onEvent: (@MainActor (TerminalSurfaceEvent) -> Void)?

    var markedTextRange = NSRange(location: NSNotFound, length: 0)
    var selectedTextRange = NSRange(location: NSNotFound, length: 0)
    var markedTextValue = ""
    var committingComposition = false
    var currentKeyEvent: NSEvent?
    var keyTextAccumulator: [String] = []

    init(app: ghostty_app_t, configuration: GhosttyTerminalConfiguration) {
        self.app = app
        self.configuration = configuration
        super.init(frame: .zero)
        wantsLayer = true
        layer?.isOpaque = true
        registerForDraggedTypes([.fileURL, .string, .URL])
        observeLifecycle()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    deinit {
        observerTokens.forEach {
            NotificationCenter.default.removeObserver($0)
            NSWorkspace.shared.notificationCenter.removeObserver($0)
        }
        if let surface { ghostty_surface_free(surface) }
        configStrings.forEach { free($0) }
    }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        accessibilityExposureDidChange()
        guard window != nil else {
            updateOcclusion()
            return
        }
        if surface == nil { createSurface() }
        updateGeometry()
        updateDisplay()
        updateOcclusion()
        updateGhosttyFocus()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if pendingCreation { createSurface() }
        updateGeometry()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateGeometry()
        updateDisplay()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColorScheme()
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted, let surface { ghostty_surface_set_focus(surface, window?.isKeyWindow == true) }
        if accepted { accessibilityFocusDidChange() }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted, let surface { ghostty_surface_set_focus(surface, false) }
        if accepted { accessibilityFocusDidChange() }
        return accepted
    }

    func report(_ event: TerminalSurfaceEvent) {
        onEvent?(event)
    }

    func renderNow() {
        guard let surface else { return }
        guard isRenderable else {
            pendingRefresh = true
            return
        }
        if pendingRefresh {
            pendingRefresh = false
            ghostty_surface_refresh(surface)
        }
        ghostty_surface_draw(surface)
    }

    func handleProcessExit(code: Int32?) {
        guard !reportedExit else { return }
        reportedExit = true
        report(.processExited(exitCode: code, reason: .processExit))
    }

    func openLink(_ raw: String) {
        switch GhosttyLinkPolicy.disposition(for: raw) {
        case let .open(url): NSWorkspace.shared.open(url)
        case let .reveal(url): NSWorkspace.shared.activateFileViewerSelecting([url])
        case .ignore: break
        }
    }

    func applyMouseShape(_ shape: ghostty_action_mouse_shape_e) {
        mouseShape = shape
        if pointerInside { Self.cursor(for: shape).set() }
    }

    func updateGhosttyFocus() {
        guard let surface, let window else { return }
        ghostty_surface_set_focus(surface, window.isKeyWindow && window.firstResponder === self)
        accessibilityFocusDidChange()
    }

    func terminate() {
        commitComposition()
        guard !destroyed, let surface else { return }
        ghostty_surface_request_close(surface)
    }

    func close() {
        guard !destroyed else { return }
        if let surface { ghostty_surface_request_close(surface) }
        destroySurface()
    }

    /// PID of the process currently in the foreground of this PTY, or `nil`
    /// when the shell has exited or Ghostty has no process to report.
    ///
    /// This is the only trustworthy answer to "what is running in this
    /// terminal". Terminal titles and OSC notification text are content the
    /// running program chooses, so they cannot distinguish an Agent from a
    /// shell that merely printed the Agent's name.
    var foregroundProcessID: pid_t? {
        guard !destroyed, let surface, !ghostty_surface_process_exited(surface) else { return nil }
        let pid = ghostty_surface_foreground_pid(surface)
        guard pid > 0, pid <= UInt64(pid_t.max) else { return nil }
        return pid_t(pid)
    }

    private func createSurface() {
        guard !destroyed, surface == nil else { return }
        let backingSize = convertToBacking(bounds).size
        guard backingSize.width > 0, backingSize.height > 0 else {
            pendingCreation = true
            return
        }
        pendingCreation = false

        var config = ghostty_surface_config_new()
        config.platform_tag = GHOSTTY_PLATFORM_MACOS
        config.platform = ghostty_platform_u(
            macos: ghostty_platform_macos_s(nsview: Unmanaged.passUnretained(self).toOpaque())
        )
        config.userdata = Unmanaged.passUnretained(self).toOpaque()
        config.scale_factor = Double(window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2)
        if let fontSize = configuration.fontSize { config.font_size = fontSize }
        config.wait_after_command = configuration.waitAfterCommand

        configStrings.forEach { free($0) }
        configStrings = []
        environment = []
        if let value = duplicate(configuration.workingDirectory) { config.working_directory = UnsafePointer(value) }
        if let value = duplicate(configuration.command) { config.command = UnsafePointer(value) }
        for (key, value) in configuration.environment.sorted(by: { $0.key < $1.key }) {
            guard let keyPointer = duplicate(key), let valuePointer = duplicate(value) else { continue }
            environment.append(ghostty_env_var_s(key: UnsafePointer(keyPointer), value: UnsafePointer(valuePointer)))
        }

        if environment.isEmpty {
            surface = ghostty_surface_new(app, &config)
        } else {
            surface = environment.withUnsafeMutableBufferPointer { buffer in
                config.env_vars = buffer.baseAddress
                config.env_var_count = buffer.count
                return ghostty_surface_new(app, &config)
            }
        }
        guard surface != nil else {
            pendingCreation = true
            return
        }
        applyColorScheme()
        updateDisplay()
        updateGeometry()
        updateOcclusion()
        updateGhosttyFocus()
        accessibilityExposureDidChange()
        report(.started)
    }

    private func applyColorScheme() {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        GhosttyRuntime.shared.applyColorScheme(
            dark ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT,
            to: surface
        )
    }

    private func duplicate(_ value: String) -> UnsafeMutablePointer<CChar>? {
        guard let pointer = strdup(value) else { return nil }
        configStrings.append(pointer)
        return pointer
    }

    private func destroySurface() {
        guard !destroyed else { return }
        destroyed = true
        if let surface { ghostty_surface_free(surface) }
        surface = nil
        accessibilityTextCache = nil
        accessibilityExposureDidChange()
        accessibilityFocusDidChange()
        configStrings.forEach { free($0) }
        configStrings = []
        environment = []
        findBar?.removeFromSuperview()
        findBar = nil
        onEvent = nil
    }

    private func updateGeometry() {
        guard let surface, window != nil else { return }
        let backingSize = convertToBacking(bounds).size
        guard backingSize.width > 0, backingSize.height > 0 else { return }
        let scale = Double(window?.backingScaleFactor ?? 2)
        if let layer {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.contentsScale = scale
            CATransaction.commit()
        }
        ghostty_surface_set_content_scale(surface, scale, scale)
        ghostty_surface_set_size(surface, UInt32(backingSize.width), UInt32(backingSize.height))
        pendingRefresh = true
        if isRenderable {
            pendingRefresh = false
            ghostty_surface_refresh(surface)
        }
    }

    private var isRenderable: Bool {
        guard !screensAsleep, let window, window.isVisible, !window.isMiniaturized else { return false }
        return window.occlusionState.contains(.visible)
    }

    private func updateDisplay() {
        guard let surface,
              let screen = window?.screen ?? NSScreen.main,
              let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32,
              displayID != lastDisplayID
        else { return }
        lastDisplayID = displayID
        ghostty_surface_set_display_id(surface, displayID)
        pendingRefresh = true
    }

    private func updateOcclusion() {
        guard let surface else {
            // A visibility value only describes a concrete renderer. Surface
            // creation can be deferred until AppKit gives us a non-zero
            // backing size, so never let an earlier no-surface call suppress
            // the first visibility report after creation.
            reportedVisibility = nil
            return
        }
        let visible = Self.ghosttyVisibility(isRenderable: isRenderable)
        guard visible != reportedVisibility else {
            if visible, pendingRefresh {
                pendingRefresh = false
                ghostty_surface_refresh(surface)
            }
            return
        }
        reportedVisibility = visible
        // Despite the C API's `set_occlusion` name, this boolean is
        // `visible`: true keeps the renderer/display link active and false
        // parks it. Passing an `occluded` value here delays terminal echo and
        // IME preedit until an unrelated refresh happens.
        ghostty_surface_set_occlusion(surface, visible)
        if visible {
            pendingRefresh = false
            updateDisplay()
            updateGeometry()
            ghostty_surface_refresh(surface)
        } else {
            pendingRefresh = true
        }
    }

    nonisolated static func ghosttyVisibility(isRenderable: Bool) -> Bool {
        isRenderable
    }

    private func retryCreationAfterWake() {
        guard !destroyed, surface == nil, wakeRetryCount < 10 else { return }
        wakeRetryCount += 1
        createSurface()
        guard surface == nil else {
            wakeRetryCount = 0
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.retryCreationAfterWake()
        }
    }

    private func observeLifecycle() {
        let center = NotificationCenter.default
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            observerTokens.append(center.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.updateGhosttyFocus()
                    self?.updateOcclusion()
                }
            })
        }
        for name in [
            NSWindow.didChangeOcclusionStateNotification,
            NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification,
            NSApplication.didHideNotification,
            NSApplication.didUnhideNotification,
        ] {
            observerTokens.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.updateOcclusion()
                    self?.accessibilityExposureDidChange()
                }
            })
        }
        observerTokens.append(center.addObserver(
            forName: NSWindow.didChangeScreenNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.updateDisplay()
                self?.updateGeometry()
            }
        })

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        observerTokens.append(workspaceCenter.addObserver(
            forName: NSWorkspace.screensDidSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.screensAsleep = true
                self?.updateOcclusion()
            }
        })
        observerTokens.append(workspaceCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.screensAsleep = false
                self.updateOcclusion()
                self.retryCreationAfterWake()
            }
        })
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaToken { removeTrackingArea(trackingAreaToken) }
        let tracking = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .cursorUpdate, .activeInKeyWindow, .inVisibleRect],
            owner: self
        )
        addTrackingArea(tracking)
        trackingAreaToken = tracking
    }

    override func cursorUpdate(with _: NSEvent) { applyMouseCursor() }
    override func mouseEntered(with event: NSEvent) { pointerInside = true; reportMousePosition(event) }
    override func mouseExited(with event: NSEvent) {
        pointerInside = false
        guard let surface, NSEvent.pressedMouseButtons == 0 else { return }
        ghostty_surface_mouse_pos(surface, -1, -1, inputModifiers(event))
    }
    override func mouseMoved(with event: NSEvent) { reportMousePosition(event); applyMouseCursor() }
    override func mouseDragged(with event: NSEvent) { mouseMoved(with: event) }
    override func rightMouseDragged(with event: NSEvent) { mouseMoved(with: event) }
    override func otherMouseDragged(with event: NSEvent) { mouseMoved(with: event) }

    private func applyMouseCursor() {
        guard !HorizontalResizeCursorOwnership.ownsCursor(in: window) else { return }
        Self.cursor(for: mouseShape).set()
    }

    private static func cursor(for shape: ghostty_action_mouse_shape_e) -> NSCursor {
        switch shape {
        case GHOSTTY_MOUSE_SHAPE_TEXT: .iBeam
        case GHOSTTY_MOUSE_SHAPE_POINTER: .pointingHand
        case GHOSTTY_MOUSE_SHAPE_CROSSHAIR: .crosshair
        case GHOSTTY_MOUSE_SHAPE_GRAB: .openHand
        case GHOSTTY_MOUSE_SHAPE_GRABBING: .closedHand
        case GHOSTTY_MOUSE_SHAPE_NOT_ALLOWED, GHOSTTY_MOUSE_SHAPE_NO_DROP: .operationNotAllowed
        case GHOSTTY_MOUSE_SHAPE_CONTEXT_MENU: .contextualMenu
        case GHOSTTY_MOUSE_SHAPE_VERTICAL_TEXT: .iBeamCursorForVerticalLayout
        case GHOSTTY_MOUSE_SHAPE_COL_RESIZE, GHOSTTY_MOUSE_SHAPE_E_RESIZE,
             GHOSTTY_MOUSE_SHAPE_W_RESIZE, GHOSTTY_MOUSE_SHAPE_EW_RESIZE: .resizeLeftRight
        case GHOSTTY_MOUSE_SHAPE_ROW_RESIZE, GHOSTTY_MOUSE_SHAPE_N_RESIZE,
             GHOSTTY_MOUSE_SHAPE_S_RESIZE, GHOSTTY_MOUSE_SHAPE_NS_RESIZE: .resizeUpDown
        default: .arrow
        }
    }
}
