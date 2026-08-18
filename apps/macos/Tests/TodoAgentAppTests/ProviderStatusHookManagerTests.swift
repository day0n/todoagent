import Darwin
import Foundation
import Testing
@testable import TodoAgentApp

@Suite("Provider status hook manager")
struct ProviderStatusHookManagerTests {
    @Test("Codex install merges every lifecycle event, backs up, and is idempotent")
    func codexInstallMergeAndIdempotence() throws {
        let fixture = try StatusHookFixture()
        defer { fixture.cleanup() }
        let config = fixture.home
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("hooks.json")
        try writeFixture(
            [
                "description": "keep me",
                "hooks": [
                    "Stop": [[
                        "matcher": "main",
                        "hooks": [["type": "command", "command": "keep-stop"]],
                    ]],
                ],
            ],
            to: config
        )

        let result = try fixture.manager.install(runtime: .codex)
        #expect(result.health == .installedRequiresProviderReview)
        let once = try loadJSON(config)
        #expect(once["description"] as? String == "keep me")
        #expect(managedCodexHandlerCount(once) == 5)
        #expect(allCommands(in: once).contains("keep-stop"))
        #expect(try permissions(config) == 0o600)
        #expect(try backupCount(fixture.support, runtime: .codex) == 1)

        try fixture.manager.install(runtime: .codex)
        let twice = try loadJSON(config)
        #expect(managedCodexHandlerCount(twice) == 5)
        #expect(try backupCount(fixture.support, runtime: .codex) == 1)
    }

    @Test("Codex uninstall removes only TodoAgent entries and keeps later user edits")
    func codexUninstallPreservesUserChanges() throws {
        let fixture = try StatusHookFixture()
        defer { fixture.cleanup() }
        try fixture.manager.install(runtime: .codex)
        let config = fixture.home
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("hooks.json")
        var document = try loadJSON(config)
        var hooks = try #require(document["hooks"] as? [String: Any])
        hooks["PostToolUse"] = [[
            "hooks": [["type": "command", "command": "user-added-after-install"]],
        ]]
        document["hooks"] = hooks
        try writeFixture(document, to: config)

        try fixture.manager.uninstall(runtime: .codex)
        let uninstalled = try loadJSON(config)
        #expect(managedCodexHandlerCount(uninstalled) == 0)
        #expect(allCommands(in: uninstalled).contains("user-added-after-install"))
        #expect(try backupCount(fixture.support, runtime: .codex) == 1)
    }

    /// Claude keeps hooks inside its general settings document, so a merge here
    /// touches a file that also holds unrelated preferences and, commonly,
    /// another status tool's handlers. Both have to survive install and
    /// uninstall untouched.
    @Test("Claude install merges into settings.json and keeps foreign hooks and preferences")
    func claudeInstallPreservesUnrelatedSettings() throws {
        let fixture = try StatusHookFixture()
        defer { fixture.cleanup() }
        let config = fixture.home
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("settings.json")
        try writeFixture(
            [
                "model": "opus",
                "env": ["FOO": "bar"],
                "hooks": [
                    // A matcher group, which is the shape Claude uses for
                    // permission prompts and the one an existing tool occupies.
                    "Notification": [[
                        "matcher": "permission_prompt",
                        "hooks": [["type": "command", "command": "foreign-blocked"]],
                    ]],
                    // A managed event that already has someone else's handler.
                    "Stop": [[
                        "hooks": [["type": "command", "command": "foreign-stop"]],
                    ]],
                ],
            ],
            to: config
        )

        let result = try fixture.manager.install(runtime: .claude)
        #expect(result.health == .installed)
        let installed = try loadJSON(config)
        #expect(installed["model"] as? String == "opus")
        #expect((installed["env"] as? [String: String])?["FOO"] == "bar")
        #expect(allCommands(in: installed).contains("foreign-blocked"))
        #expect(allCommands(in: installed).contains("foreign-stop"))
        #expect(managedClaudeHandlerCount(installed) == 5)
        #expect(try permissions(config) == 0o600)
        #expect(try backupCount(fixture.support, runtime: .claude) == 1)

        // Re-installing must not stack a second copy of our handlers.
        try fixture.manager.install(runtime: .claude)
        #expect(managedClaudeHandlerCount(try loadJSON(config)) == 5)
        #expect(try backupCount(fixture.support, runtime: .claude) == 1)

        try fixture.manager.uninstall(runtime: .claude)
        let uninstalled = try loadJSON(config)
        #expect(managedClaudeHandlerCount(uninstalled) == 0)
        #expect(uninstalled["model"] as? String == "opus")
        #expect(allCommands(in: uninstalled).contains("foreign-blocked"))
        #expect(allCommands(in: uninstalled).contains("foreign-stop"))
    }

    @Test("CLAUDE_CONFIG_DIR redirects the settings document only when absolute")
    func claudeConfigurationDirectoryOverride() throws {
        #expect(
            ProviderStatusHookManager.environmentClaudeConfigurationDirectory(
                environment: ["CLAUDE_CONFIG_DIR": "/tmp/custom-claude"]
            )?.path == "/tmp/custom-claude"
        )
        // A relative or empty value would resolve against the App's working
        // directory and write a settings file the user never configured.
        for value in ["", "  ", "relative/dir"] {
            #expect(
                ProviderStatusHookManager.environmentClaudeConfigurationDirectory(
                    environment: ["CLAUDE_CONFIG_DIR": value]
                ) == nil
            )
        }
        #expect(ProviderStatusHookManager.environmentClaudeConfigurationDirectory(environment: [:]) == nil)
    }

    @Test("Cursor install preserves unknown fields and existing handlers")
    func cursorInstallAndUninstall() throws {
        let fixture = try StatusHookFixture()
        defer { fixture.cleanup() }
        let config = fixture.home
            .appendingPathComponent(".cursor", isDirectory: true)
            .appendingPathComponent("hooks.json")
        try writeFixture(
            [
                "version": 1,
                "custom": ["keep": true],
                "hooks": ["stop": [["command": "keep-cursor"]]],
            ],
            to: config
        )

        let result = try fixture.manager.install(runtime: .cursor)
        #expect(result.health == .installed)
        let installed = try loadJSON(config)
        #expect((installed["custom"] as? [String: Bool])?["keep"] == true)
        #expect(allCommands(in: installed).contains("keep-cursor"))
        #expect(managedCursorHandlerCount(installed) == 4)

        try fixture.manager.uninstall(runtime: .cursor)
        let uninstalled = try loadJSON(config)
        #expect(allCommands(in: uninstalled).contains("keep-cursor"))
        #expect(managedCursorHandlerCount(uninstalled) == 0)
    }

    @Test("malformed JSON and unsupported Cursor versions are never overwritten")
    func invalidConfigurationFailsClosed() throws {
        let fixture = try StatusHookFixture()
        defer { fixture.cleanup() }
        let config = fixture.home
            .appendingPathComponent(".cursor", isDirectory: true)
            .appendingPathComponent("hooks.json")
        try FileManager.default.createDirectory(
            at: config.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let malformed = Data("{ definitely-not-json".utf8)
        try malformed.write(to: config)

        #expect(throws: ProviderStatusHookError.malformedConfiguration(config.path)) {
            try fixture.manager.install(runtime: .cursor)
        }
        #expect(try Data(contentsOf: config) == malformed)

        try writeFixture(["version": 2, "hooks": [:]], to: config)
        let versionTwo = try Data(contentsOf: config)
        #expect(throws: ProviderStatusHookError.unsupportedConfigurationVersion(config.path)) {
            try fixture.manager.install(runtime: .cursor)
        }
        #expect(try Data(contentsOf: config) == versionTwo)
    }

    @Test("unknown provider event shapes are never overwritten")
    func unknownManagedEventShapeFailsClosed() throws {
        let fixture = try StatusHookFixture()
        defer { fixture.cleanup() }
        let config = fixture.home
            .appendingPathComponent(".cursor", isDirectory: true)
            .appendingPathComponent("hooks.json")
        try writeFixture(
            ["version": 1, "hooks": ["stop": ["future": "schema"]]],
            to: config
        )
        let original = try Data(contentsOf: config)

        #expect(throws: ProviderStatusHookError.malformedConfiguration(config.path)) {
            try fixture.manager.install(runtime: .cursor)
        }
        #expect(try Data(contentsOf: config) == original)
    }

    @Test("symbolic link configurations are rejected without touching their targets")
    func symbolicLinkRejected() throws {
        let fixture = try StatusHookFixture()
        defer { fixture.cleanup() }
        let directory = fixture.home.appendingPathComponent(".cursor", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = fixture.root.appendingPathComponent("target.json")
        let original = Data("{\"version\":1,\"hooks\":{}}".utf8)
        try original.write(to: target)
        let config = directory.appendingPathComponent("hooks.json")
        try FileManager.default.createSymbolicLink(at: config, withDestinationURL: target)

        #expect(throws: ProviderStatusHookError.symbolicLink(config.path)) {
            try fixture.manager.install(runtime: .cursor)
        }
        #expect(try Data(contentsOf: target) == original)
    }

    @Test("missing or nonexecutable runner never writes provider configuration")
    func missingRunnerFailsClosed() throws {
        let fixture = try StatusHookFixture()
        defer { fixture.cleanup() }
        #expect(chmod(fixture.runner.path, mode_t(0o600)) == 0)

        #expect(throws: ProviderStatusHookError.runnerNotFound) {
            try fixture.manager.install(runtime: .codex)
        }
        #expect(
            FileManager.default.fileExists(
                atPath: fixture.home
                    .appendingPathComponent(".codex/hooks.json")
                    .path
            ) == false
        )
    }

    @Test("wrapper publication failure leaves provider configuration untouched")
    func wrapperFailurePrecedesConfigurationCommit() throws {
        let fixture = try StatusHookFixture()
        defer { fixture.cleanup() }
        let config = fixture.home
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("hooks.json")
        let original: [String: Any] = [
            "hooks": [
                "Stop": [[
                    "hooks": [["type": "command", "command": "keep-stop"]],
                ]],
            ],
        ]
        try writeFixture(original, to: config)
        let originalData = try Data(contentsOf: config)

        // A directory at the final wrapper path makes the exclusive atomic
        // replacement fail without making the provider config unwritable.
        let wrapper = fixture.support.appendingPathComponent("codex-status-hook-v1")
        try FileManager.default.createDirectory(
            at: wrapper,
            withIntermediateDirectories: true
        )

        #expect(throws: (any Error).self) {
            try fixture.manager.install(runtime: .codex)
        }
        #expect(try Data(contentsOf: config) == originalData)
        #expect(try backupCount(fixture.support, runtime: .codex) == 0)
    }

    @Test("installed wrapper stays silent and successful after the App moves")
    func missingInstalledRunnerIsSilentAndSuccessful() throws {
        let fixture = try StatusHookFixture()
        defer { fixture.cleanup() }
        try fixture.manager.install(runtime: .codex)
        let wrapper = fixture.support.appendingPathComponent("codex-status-hook-v1")
        try FileManager.default.removeItem(at: fixture.runner)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [wrapper.path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()

        #expect(process.terminationStatus == 0)
        #expect(output.fileHandleForReading.readDataToEndOfFile().isEmpty)
    }
}

private let codexEvents = [
    "SessionStart", "UserPromptSubmit", "PermissionRequest", "Stop", "SessionEnd",
]

private let cursorEvents = ["sessionStart", "beforeSubmitPrompt", "stop", "sessionEnd"]

private let claudeEvents = [
    "SessionStart", "UserPromptSubmit", "PermissionRequest", "Stop", "SessionEnd",
]

private func writeFixture(_ document: [String: Any], to url: URL) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    let data = try JSONSerialization.data(
        withJSONObject: document,
        options: [.prettyPrinted, .sortedKeys]
    )
    try data.write(to: url, options: .atomic)
    #expect(chmod(url.path, mode_t(0o600)) == 0)
}

private func loadJSON(_ url: URL) throws -> [String: Any] {
    try #require(
        JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
    )
}

private func allCommands(in value: Any) -> [String] {
    if let object = value as? [String: Any] {
        return object.flatMap { key, value in
            (key == "command" ? [value as? String].compactMap { $0 } : []) + allCommands(in: value)
        }
    }
    if let array = value as? [Any] { return array.flatMap(allCommands(in:)) }
    return []
}

private func managedCodexHandlerCount(_ document: [String: Any]) -> Int {
    guard let hooks = document["hooks"] as? [String: Any] else { return 0 }
    return codexEvents.reduce(into: 0) { count, event in
        guard let groups = hooks[event] as? [Any] else { return }
        for group in groups {
            guard let object = group as? [String: Any],
                  let handlers = object["hooks"] as? [Any]
            else { continue }
            count += handlers.filter {
                (($0 as? [String: Any])?["command"] as? String)?.contains("codex-status-hook-v1") == true
            }.count
        }
    }
}

private func managedClaudeHandlerCount(_ document: [String: Any]) -> Int {
    guard let hooks = document["hooks"] as? [String: Any] else { return 0 }
    return claudeEvents.reduce(into: 0) { count, event in
        guard let groups = hooks[event] as? [Any] else { return }
        for group in groups {
            guard let object = group as? [String: Any],
                  let handlers = object["hooks"] as? [Any]
            else { continue }
            count += handlers.filter {
                (($0 as? [String: Any])?["command"] as? String)?
                    .contains("claude-status-hook-v1") == true
            }.count
        }
    }
}

private func managedCursorHandlerCount(_ document: [String: Any]) -> Int {
    guard let hooks = document["hooks"] as? [String: Any] else { return 0 }
    return cursorEvents.reduce(into: 0) { count, event in
        guard let handlers = hooks[event] as? [Any] else { return }
        count += handlers.filter {
            (($0 as? [String: Any])?["command"] as? String)?.contains("cursor-status-hook-v1") == true
        }.count
    }
}

private func backupCount(_ support: URL, runtime: RuntimeKind) throws -> Int {
    let directory = support
        .appendingPathComponent("Backups", isDirectory: true)
        .appendingPathComponent(runtime.rawValue, isDirectory: true)
    guard FileManager.default.fileExists(atPath: directory.path) else { return 0 }
    return try FileManager.default.contentsOfDirectory(atPath: directory.path).count
}

private func permissions(_ url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return try #require(attributes[.posixPermissions] as? NSNumber).intValue & 0o777
}
