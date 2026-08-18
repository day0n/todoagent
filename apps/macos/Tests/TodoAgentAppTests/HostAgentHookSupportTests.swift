import Foundation
import Testing
@testable import TodoAgentApp

struct HostAgentHookSupportTests {
    @Test("host hook environment carries the socket credentials Claude and Codex need")
    func hostHookEnvironment() {
        let environment = HostAgentHookSupport.environment(
            sessionID: "session-1",
            runID: "run-1",
            runtime: .claude,
            socketPath: "/tmp/todoagent-1/status.sock",
            hookToken: "hook-token"
        )

        #expect(environment["TODOAGENT_SESSION_ID"] == "session-1")
        #expect(environment["TODOAGENT_RUN_ID"] == "run-1")
        #expect(environment["TODOAGENT_RUNTIME"] == "claude")
        #expect(environment["TODOAGENT_STATUS_SOCKET"] == "/tmp/todoagent-1/status.sock")
        #expect(environment["TODOAGENT_HOOK_TOKEN"] == "hook-token")
    }

    /// Regression guard. TodoAgent used to prepend a `claude` shim directory to
    /// `PATH` so it could inject `--settings`. That can never work in a host
    /// shell: a login shell re-derives `PATH` through `path_helper`, and a user
    /// shell function named `claude` wins over any `PATH` lookup regardless of
    /// order. Hooks are installed once per account instead, so overriding
    /// `PATH` for a Session has no remaining purpose.
    @Test("host hook environment never overrides PATH")
    func hostHookEnvironmentLeavesPathAlone() {
        let environment = HostAgentHookSupport.environment(
            sessionID: "session-1",
            runID: "run-1",
            runtime: .claude,
            socketPath: "/tmp/todoagent-1/status.sock",
            hookToken: "hook-token"
        )

        #expect(environment["PATH"] == nil)
        #expect(environment.count == 5)
    }
}
