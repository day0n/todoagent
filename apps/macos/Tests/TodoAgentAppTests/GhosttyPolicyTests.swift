import Foundation
import Testing
@testable import TodoAgentApp

struct GhosttyPolicyTests {
    @Test func commandBuilderQuotesEveryArgumentAndRejectsOtherExecutables() throws {
        let command = try GhosttyCommandBuilder.command(
            executable: "/Applications/TodoAgent.app/Contents/Resources/todoagent-terminal-runner",
            arguments: ["--descriptor", "/tmp/a b'c.json"]
        )
        #expect(command == "'/Applications/TodoAgent.app/Contents/Resources/todoagent-terminal-runner' '--descriptor' '/tmp/a b'\\''c.json'")
        #expect(throws: GhosttyTerminalError.invalidLaunchPlan) {
            try GhosttyCommandBuilder.command(executable: "/bin/sh", arguments: ["-c", "echo unsafe"])
        }
        #expect(throws: GhosttyTerminalError.invalidLaunchPlan) {
            try GhosttyCommandBuilder.command(
                executable: "/tmp/todoagent-terminal-runner",
                arguments: ["--descriptor", "relative.json"]
            )
        }
    }

    @Test func hostShellCommandUsesLoginShellAndRejectsUnknownBinaries() throws {
        #expect(
            try GhosttyCommandBuilder.hostShellCommand(environment: ["SHELL": "/bin/zsh"])
                == "'/bin/zsh' '-l'"
        )
        #expect(
            try GhosttyCommandBuilder.hostShellCommand(
                workingDirectory: "/Users/me/My Project",
                environment: ["SHELL": "/bin/zsh"]
            ) == "'/bin/zsh' '-l' '-c' 'cd -- '\\''/Users/me/My Project'\\'' && exec '\\''/bin/zsh'\\'''"
        )
        #expect(throws: GhosttyTerminalError.invalidLaunchPlan) {
            try GhosttyCommandBuilder.hostShellCommand(environment: ["SHELL": "/usr/bin/python3"])
        }
        #expect(throws: GhosttyTerminalError.invalidLaunchPlan) {
            try GhosttyCommandBuilder.hostShellCommand(environment: ["SHELL": "zsh"])
        }
        #expect(throws: GhosttyTerminalError.invalidLaunchPlan) {
            try GhosttyCommandBuilder.hostShellCommand(
                workingDirectory: "relative/project",
                environment: ["SHELL": "/bin/zsh"]
            )
        }
    }

    @Test func officialLaunchCommandChangesDirectoryBeforeTheRunner() throws {
        #expect(
            try GhosttyCommandBuilder.officialLaunchCommand(
                executable: "/Applications/TodoAgent.app/Contents/Resources/todoagent-terminal-runner",
                arguments: ["--descriptor", "/tmp/a b'c.json"],
                workingDirectory: "/Users/me/My Project"
            ) == "cd -- '/Users/me/My Project' && '/Applications/TodoAgent.app/Contents/Resources/todoagent-terminal-runner' '--descriptor' '/tmp/a b'\\''c.json'"
        )
        #expect(throws: GhosttyTerminalError.invalidLaunchPlan) {
            try GhosttyCommandBuilder.changeDirectoryCommand(workingDirectory: "relative/project")
        }
    }

    @Test("missing bound workspace is rejected before a terminal surface is created")
    func missingBoundWorkspaceFailsBeforeSurfaceCreation() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("todoagent-working-directory-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(throws: Never.self) {
            try GhosttyLaunchPlanValidator.validateWorkingDirectory(directory.path)
        }

        let missingPath = directory.appendingPathComponent("missing", isDirectory: true).path
        #expect(throws: GhosttyTerminalError.workingDirectoryUnavailable(missingPath)) {
            try GhosttyLaunchPlanValidator.validateWorkingDirectory(missingPath)
        }
        #expect(throws: GhosttyTerminalError.invalidLaunchPlan) {
            try GhosttyLaunchPlanValidator.validateWorkingDirectory("relative/project")
        }
    }

    @Test("stored symlink workspace is unavailable to UI and surface preflight")
    func symlinkWorkspaceMatchesEnginePreflightPolicy() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("todoagent-symlink-workspace-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        let target = root.appendingPathComponent("target", isDirectory: true)
        let link = root.appendingPathComponent("linked", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(TerminalWorkingDirectoryPolicy.isAvailable(target.path))
        #expect(TerminalWorkingDirectoryPolicy.isAvailable(link.path) == false)
        #expect(throws: GhosttyTerminalError.workingDirectoryUnavailable(link.path)) {
            try GhosttyLaunchPlanValidator.validateWorkingDirectory(link.path)
        }
    }

    @Test func linkPolicyAllowsWebAndLocalFilesOnly() {
        #expect(GhosttyLinkPolicy.disposition(for: "https://example.com") == .open(URL(string: "https://example.com")!))
        #expect(GhosttyLinkPolicy.disposition(for: "javascript:alert(1)") == .ignore)
        #expect(GhosttyLinkPolicy.disposition(for: "file://remote.example/tmp/a", localHosts: ["localhost"]) == .ignore)
        #expect(GhosttyLinkPolicy.disposition(for: "file:///net/server/share", localHosts: ["localhost"]) == .ignore)
        #expect(
            GhosttyLinkPolicy.disposition(for: "file:///tmp/a/../b", localHosts: ["localhost"])
                == .reveal(URL(fileURLWithPath: "/tmp/b"))
        )
    }

    @Test func resourceResolverRequiresAllRuntimePieces() {
        let root = URL(fileURLWithPath: "/bundle", isDirectory: true)
        let expected = [
            "/bundle/ghostty/shell-integration",
            "/bundle/ghostty/themes",
            "/bundle/terminfo/78/xterm-ghostty",
        ]
        let found = GhosttyResourceResolver(
            candidates: [root.appendingPathComponent("ghostty", isDirectory: true)],
            isDirectory: { expected.contains($0.path) },
            fileExists: { expected.contains($0.path) }
        ).resolve()
        #expect(found == root.appendingPathComponent("ghostty", isDirectory: true))
        let missing = GhosttyResourceResolver(
            candidates: [root.appendingPathComponent("ghostty", isDirectory: true)],
            isDirectory: { expected.contains($0.path) },
            fileExists: { $0.path != expected.last }
        ).resolve()
        #expect(missing == nil)
    }

    @Test func managedConfigurationBoundsTerminalMemoryAndClipboardAccess() throws {
        let url = try #require(
            TodoAgentResourceBundle.url(
                forResource: "todoagent-ghostty",
                withExtension: "conf"
            )
        )
        let configuration = try String(contentsOf: url, encoding: .utf8)
        #expect(configuration.contains("scrollback-limit = 4000000"))
        #expect(configuration.contains("image-storage-limit = 16000000"))
        #expect(configuration.contains("clipboard-read = ask"))
        #expect(configuration.contains("clipboard-paste-protection = true"))
        #expect(configuration.contains("title-report = false"))
    }

    @Test func ghosttyOcclusionAPIReceivesVisibilityPolarity() {
        // Ghostty's C API is named `set_occlusion`, but its bool parameter is
        // `visible`. A visible workbench must therefore report true; otherwise
        // the renderer is parked and terminal input appears only on a later
        // unrelated refresh.
        #expect(GhosttySurfaceView.ghosttyVisibility(isRenderable: true))
        #expect(!GhosttySurfaceView.ghosttyVisibility(isRenderable: false))
    }
}
