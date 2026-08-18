// Adapted from umputun/agterm and thdxg/macterm (MIT).

import AppKit
import Foundation
import GhosttyKit
import os

private let ghosttyRuntimeLogger = Logger(subsystem: "org.opencreator.TodoAgent", category: "GhosttyRuntime")

/// Process-global libghostty state. Surfaces are still individually owned by
/// `GhosttyTerminalSession`; this object only owns Ghostty's shared app/config.
@MainActor
final class GhosttyRuntime {
    static let shared = GhosttyRuntime()

    private(set) var app: ghostty_app_t?
    private(set) var config: ghostty_config_t?
    let callbacks = GhosttyCallbacks()
    private var resourcePath: String?
    private(set) var startupError: GhosttyTerminalError?

    private init() {
        guard let resources = GhosttyBundledResources.resolve() else {
            unsetenv("GHOSTTY_RESOURCES_DIR")
            startupError = .resourcesMissing
            return
        }
        resourcePath = resources.path
        setenv("GHOSTTY_RESOURCES_DIR", resources.path, 1)

        guard ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) == GHOSTTY_SUCCESS else {
            startupError = .initializationFailed
            return
        }
        guard let configuration = ghostty_config_new() else {
            startupError = .configurationFailed
            return
        }
        guard let managedConfig = TodoAgentResourceBundle.url(
            forResource: "todoagent-ghostty",
            withExtension: "conf"
        ) else {
            ghostty_config_free(configuration)
            ghosttyRuntimeLogger.error("managed Ghostty config is missing")
            startupError = .configurationFailed
            return
        }
        ghostty_config_load_file(configuration, managedConfig.path)
        ghostty_config_finalize(configuration)
        guard ghostty_config_diagnostics_count(configuration) == 0 else {
            ghostty_config_free(configuration)
            startupError = .configurationFailed
            return
        }

        var runtime = ghostty_runtime_config_s()
        runtime.userdata = Unmanaged.passUnretained(self).toOpaque()
        runtime.supports_selection_clipboard = true
        runtime.wakeup_cb = { _ in GhosttyRuntime.shared.callbacks.wakeup() }
        runtime.action_cb = { _, target, action in
            GhosttyRuntime.shared.callbacks.action(target: target, action: action)
        }
        runtime.read_clipboard_cb = { userdata, _, state in
            GhosttyRuntime.shared.callbacks.readClipboard(userdata: userdata, state: state)
        }
        runtime.confirm_read_clipboard_cb = { userdata, content, state, request in
            GhosttyRuntime.shared.callbacks.confirmReadClipboard(
                userdata: userdata,
                content: content,
                state: state,
                request: request
            )
        }
        runtime.write_clipboard_cb = { userdata, _, content, count, confirm in
            GhosttyRuntime.shared.callbacks.writeClipboard(
                userdata: userdata,
                content: content,
                count: count,
                confirm: confirm
            )
        }
        runtime.close_surface_cb = { userdata, _ in
            GhosttyRuntime.shared.callbacks.closeSurface(userdata: userdata)
        }

        guard let created = ghostty_app_new(&runtime, configuration) else {
            ghostty_config_free(configuration)
            startupError = .appCreationFailed
            return
        }
        config = configuration
        app = created
    }

    func requireApp() throws -> ghostty_app_t {
        if let startupError { throw startupError }
        guard let app else { throw GhosttyTerminalError.appCreationFailed }
        return app
    }

    func tick() {
        guard let app else { return }
        ghostty_app_tick(app)
    }

    func reloadConfig(reloadApp: Bool, surface: ghostty_surface_t?) {
        guard let config else { return }
        if reloadApp, let app {
            ghostty_app_update_config(app, config)
        }
        if let surface {
            ghostty_surface_update_config(surface, config)
        }
    }

    func applyColorScheme(_ scheme: ghostty_color_scheme_e, to surface: ghostty_surface_t?) {
        if let config, let surface {
            ghostty_surface_update_config(surface, config)
        }
        if let app {
            ghostty_app_set_color_scheme(app, scheme)
        }
        if let surface {
            ghostty_surface_set_color_scheme(surface, scheme)
        }
    }

}

/// C callbacks may arrive on Ghostty worker threads. Values owned by the C call
/// are copied before dispatching to the main actor.
final class GhosttyCallbacks: @unchecked Sendable {
    private let tickScheduled = OSAllocatedUnfairLock(initialState: false)

    func wakeup() {
        let alreadyScheduled = tickScheduled.withLock { scheduled -> Bool in
            if scheduled { return true }
            scheduled = true
            return false
        }
        guard !alreadyScheduled else { return }
        DispatchQueue.main.async { [self] in
            tickScheduled.withLock { $0 = false }
            GhosttyRuntime.shared.tick()
        }
    }

    func action(target: ghostty_target_s, action: ghostty_action_s) -> Bool {
        switch action.tag {
        case GHOSTTY_ACTION_RENDER:
            guard let view = view(from: target) else { return true }
            DispatchQueue.main.async { view.renderNow() }
            return true
        case GHOSTTY_ACTION_SET_TITLE:
            guard let view = view(from: target) else { return true }
            let title = action.action.set_title.title.map(String.init(cString:))
            DispatchQueue.main.async { view.report(.titleChanged(title)) }
            return true
        case GHOSTTY_ACTION_PWD:
            guard let view = view(from: target), let pointer = action.action.pwd.pwd else { return true }
            let path = String(cString: pointer)
            DispatchQueue.main.async { view.report(.workingDirectoryChanged(path)) }
            return true
        case GHOSTTY_ACTION_DESKTOP_NOTIFICATION:
            guard let view = view(from: target) else { return true }
            let title = action.action.desktop_notification.title.map(String.init(cString:)) ?? ""
            let body = action.action.desktop_notification.body.map(String.init(cString:)) ?? ""
            DispatchQueue.main.async {
                view.report(.desktopNotification(title: title, body: body))
            }
            return true
        case GHOSTTY_ACTION_RING_BELL:
            guard let view = view(from: target) else { return true }
            DispatchQueue.main.async { view.report(.attentionRequested) }
            return true
        case GHOSTTY_ACTION_OPEN_URL:
            guard let view = view(from: target), let pointer = action.action.open_url.url else { return true }
            let string = String(
                decoding: UnsafeRawBufferPointer(start: pointer, count: Int(action.action.open_url.len)),
                as: UTF8.self
            )
            DispatchQueue.main.async { view.openLink(string) }
            return true
        case GHOSTTY_ACTION_MOUSE_SHAPE:
            guard let view = view(from: target) else { return true }
            let shape = action.action.mouse_shape
            DispatchQueue.main.async { view.applyMouseShape(shape) }
            return true
        case GHOSTTY_ACTION_MOUSE_VISIBILITY:
            let hidden = action.action.mouse_visibility == GHOSTTY_MOUSE_HIDDEN
            DispatchQueue.main.async { NSCursor.setHiddenUntilMouseMoves(hidden) }
            return true
        case GHOSTTY_ACTION_START_SEARCH:
            guard let view = view(from: target) else { return true }
            let needle = action.action.start_search.needle.map(String.init(cString:)) ?? ""
            DispatchQueue.main.async { view.showFindBar(initialNeedle: needle) }
            return true
        case GHOSTTY_ACTION_END_SEARCH:
            guard let view = view(from: target) else { return true }
            DispatchQueue.main.async { view.hideFindBar() }
            return true
        case GHOSTTY_ACTION_SEARCH_TOTAL:
            guard let view = view(from: target) else { return true }
            let total = action.action.search_total.total
            DispatchQueue.main.async { view.updateFindCount(total: total) }
            return true
        case GHOSTTY_ACTION_SEARCH_SELECTED:
            guard let view = view(from: target) else { return true }
            let selected = action.action.search_selected.selected
            DispatchQueue.main.async { view.updateFindSelection(selected: selected) }
            return true
        case GHOSTTY_ACTION_RELOAD_CONFIG:
            // `set_color_scheme` asks the embedder to push the current config
            // back onto the app/surface. Without this, the ANSI palette can
            // stay unset and TUI apps render as default white.
            let reloadApp = target.tag == GHOSTTY_TARGET_APP
            let surface = target.tag == GHOSTTY_TARGET_SURFACE ? target.target.surface : nil
            DispatchQueue.main.async {
                GhosttyRuntime.shared.reloadConfig(reloadApp: reloadApp, surface: surface)
            }
            return true
        case GHOSTTY_ACTION_SHOW_CHILD_EXITED:
            // Consume Ghostty's "press any key" fallback. TodoAgent owns the
            // session lifecycle and reports the process exit itself.
            guard let view = view(from: target) else { return true }
            let code = Int32(bitPattern: action.action.child_exited.exit_code)
            DispatchQueue.main.async { view.handleProcessExit(code: code) }
            return true
        default:
            return false
        }
    }

    func readClipboard(userdata: UnsafeMutableRawPointer?, state: UnsafeMutableRawPointer?) -> Bool {
        // libghostty permits asynchronous completion. Never touch AppKit's
        // global pasteboard from a Ghostty worker callback; retain only the
        // opaque request values and complete it on the main queue.
        nonisolated(unsafe) let requestUserdata = userdata
        nonisolated(unsafe) let requestState = state
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let text = Self.pasteboardText() ?? ""
            text.withCString {
                ghostty_surface_complete_clipboard_request(
                    self.surface(from: requestUserdata),
                    $0,
                    requestState,
                    false
                )
            }
        }
        return true
    }

    func confirmReadClipboard(
        userdata: UnsafeMutableRawPointer?,
        content: UnsafePointer<CChar>?,
        state: UnsafeMutableRawPointer?,
        request: ghostty_clipboard_request_e
    ) {
        guard request == GHOSTTY_CLIPBOARD_REQUEST_OSC_52_READ else {
            guard let content else { return }
            ghostty_surface_complete_clipboard_request(surface(from: userdata), content, state, true)
            return
        }
        guard let userdata else { return }
        let view = Unmanaged<GhosttySurfaceView>.fromOpaque(userdata).takeUnretainedValue()
        let copied = content.map(String.init(cString:)) ?? ""
        nonisolated(unsafe) let requestState = state
        DispatchQueue.main.async {
            GhosttyClipboardPromptController.shared.request(.read, requester: view) { allowed in
                guard let surface = view.surface else { return }
                let delivered = allowed ? copied : ""
                delivered.withCString {
                    ghostty_surface_complete_clipboard_request(surface, $0, requestState, true)
                }
            }
        }
    }

    func writeClipboard(
        userdata: UnsafeMutableRawPointer?,
        content: UnsafePointer<ghostty_clipboard_content_s>?,
        count: Int,
        confirm: Bool
    ) {
        guard let content, count > 0 else { return }
        var copied: String?
        for item in UnsafeBufferPointer(start: content, count: count) {
            guard let mime = item.mime, String(cString: mime).hasPrefix("text/plain"), let data = item.data else {
                continue
            }
            copied = String(cString: data)
            break
        }
        guard let copied else { return }
        guard confirm else {
            DispatchQueue.main.async { Self.setPasteboard(copied) }
            return
        }
        guard let userdata else { return }
        let view = Unmanaged<GhosttySurfaceView>.fromOpaque(userdata).takeUnretainedValue()
        DispatchQueue.main.async {
            GhosttyClipboardPromptController.shared.request(.write, requester: view) { allowed in
                if allowed { Self.setPasteboard(copied) }
            }
        }
    }

    func closeSurface(userdata: UnsafeMutableRawPointer?) {
        guard let userdata else { return }
        let view = Unmanaged<GhosttySurfaceView>.fromOpaque(userdata).takeUnretainedValue()
        DispatchQueue.main.async { view.handleProcessExit(code: nil) }
    }

    private func view(from target: ghostty_target_s) -> GhosttySurfaceView? {
        guard target.tag == GHOSTTY_TARGET_SURFACE,
              let surface = target.target.surface,
              let userdata = ghostty_surface_userdata(surface)
        else { return nil }
        return Unmanaged<GhosttySurfaceView>.fromOpaque(userdata).takeUnretainedValue()
    }

    private func surface(from userdata: UnsafeMutableRawPointer?) -> ghostty_surface_t? {
        guard let userdata else { return nil }
        return Unmanaged<GhosttySurfaceView>.fromOpaque(userdata).takeUnretainedValue().surface
    }

    private static func pasteboardText() -> String? {
        if let urls = NSPasteboard.general.readObjects(forClasses: [NSURL.self]) as? [URL] {
            let escaped = urls.map { GhosttyShellEscape.argument($0.isFileURL ? $0.path(percentEncoded: false) : $0.absoluteString) }
            if !escaped.isEmpty { return escaped.joined(separator: " ") }
        }
        return NSPasteboard.general.string(forType: .string).flatMap { $0.isEmpty ? nil : $0 }
    }

    private static func setPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
