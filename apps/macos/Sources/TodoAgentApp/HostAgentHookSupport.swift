import Foundation

/// Exposes the authenticated status-socket credentials to a host PTY, so an
/// Agent the user starts by hand can report its lifecycle back to TodoAgent.
///
/// The hook definitions themselves are installed once per account by
/// `ProviderStatusHookManager`, not per Session. An earlier design tried to
/// inject Claude's `--settings` through a `claude` shim placed at the front of
/// `PATH`; that could never work for a host shell, because a login shell
/// re-derives `PATH` (`/etc/zprofile` runs `path_helper`) and because a user
/// shell function named `claude` takes precedence over any `PATH` lookup.
///
/// Outside a TodoAgent Session these variables are absent, so the installed
/// hooks find no socket and exit without sending anything.
enum HostAgentHookSupport {
    static func environment(
        sessionID: String,
        runID: String,
        runtime: RuntimeKind,
        socketPath: String,
        hookToken: String
    ) -> [String: String] {
        [
            "TODOAGENT_SESSION_ID": sessionID,
            "TODOAGENT_RUN_ID": runID,
            "TODOAGENT_RUNTIME": runtime.rawValue,
            "TODOAGENT_STATUS_SOCKET": socketPath,
            "TODOAGENT_HOOK_TOKEN": hookToken,
        ]
    }
}
