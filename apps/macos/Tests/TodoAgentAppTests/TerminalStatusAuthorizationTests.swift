import Foundation
import Testing
@testable import TodoAgentApp

@Suite("Terminal status authorization")
@MainActor
struct TerminalStatusAuthorizationTests {
    @Test("each runtime persists an independent authorization choice")
    func perRuntimeChoices() throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(TerminalStatusAuthorization.state(for: .codex, defaults: defaults) == .notAuthorized)
        #expect(TerminalStatusAuthorization.state(for: .claude, defaults: defaults) == .notAuthorized)

        TerminalStatusAuthorization.set(.enabled, for: .codex, defaults: defaults)
        TerminalStatusAuthorization.set(.skipped, for: .claude, defaults: defaults)

        #expect(TerminalStatusAuthorization.state(for: .codex, defaults: defaults) == .enabled)
        #expect(TerminalStatusAuthorization.state(for: .claude, defaults: defaults) == .skipped)
        #expect(TerminalStatusAuthorization.state(for: .cursor, defaults: defaults) == .notAuthorized)
    }

    @Test("Claude authorization installs user level hooks and uninstall returns to skipped")
    func claudeAuthorization() throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let fixture = try StatusHookFixture()
        defer { fixture.cleanup() }
        let settings = fixture.home
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("settings.json")

        try TerminalStatusAuthorization.enable(
            for: .claude,
            defaults: defaults,
            manager: fixture.manager
        )
        #expect(TerminalStatusAuthorization.state(for: .claude, defaults: defaults) == .enabled)
        #expect(
            TerminalStatusAuthorization.presentation(
                for: .claude,
                defaults: defaults,
                manager: fixture.manager
            ).isHealthy
        )
        // Claude reads hooks from its user-level settings document, so enabling
        // has to leave one behind. A run-scoped file could not reach a `claude`
        // the user starts by hand.
        #expect(FileManager.default.fileExists(atPath: settings.path))

        try TerminalStatusAuthorization.uninstall(
            for: .claude,
            defaults: defaults,
            manager: fixture.manager
        )
        #expect(TerminalStatusAuthorization.state(for: .claude, defaults: defaults) == .skipped)
        #expect(
            TerminalStatusAuthorization.presentation(
                for: .claude,
                defaults: defaults,
                manager: fixture.manager
            ).isHealthy == false
        )
    }

    /// An account that authorized Claude under the older run-scoped integration
    /// has `enabled` stored while nothing exists on disk, because that version
    /// passed `--settings` per Run and installed no files. Without re-prompting,
    /// such an account would never get the user-level hooks a host shell needs,
    /// and its terminals would stay silent forever.
    @Test("consent is re-requested when enabled is stored but nothing is installed")
    func consentPromptReopensForUninstalledEnabledState() {
        for health in [ProviderStatusHookHealth.notInstalled, .needsRepair("missing wrapper")] {
            #expect(
                TerminalStatusAuthorization.needsConsentPrompt(state: .enabled, health: health)
            )
        }

        // A working install must never nag.
        for health in [ProviderStatusHookHealth.installed, .installedRequiresProviderReview] {
            #expect(
                TerminalStatusAuthorization
                    .needsConsentPrompt(state: .enabled, health: health) == false
            )
        }

        // A declined prompt stays declined, whatever the disk says.
        for health in [
            ProviderStatusHookHealth.notInstalled,
            .needsRepair("missing wrapper"),
            .installed,
        ] {
            #expect(
                TerminalStatusAuthorization
                    .needsConsentPrompt(state: .skipped, health: health) == false
            )
        }

        #expect(
            TerminalStatusAuthorization
                .needsConsentPrompt(state: .notAuthorized, health: .notInstalled)
        )
    }

    @Test("unsupported Kiro cannot be represented as enabled")
    func unsupportedKiro() throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let fixture = try StatusHookFixture()
        defer { fixture.cleanup() }

        #expect(throws: ProviderStatusHookError.unsupportedRuntime(.kiro)) {
            try TerminalStatusAuthorization.enable(
                for: .kiro,
                defaults: defaults,
                manager: fixture.manager
            )
        }
        #expect(TerminalStatusAuthorization.state(for: .kiro, defaults: defaults) == .notAuthorized)
        #expect(
            TerminalStatusAuthorization.presentation(
                for: .kiro,
                defaults: defaults,
                manager: fixture.manager
            ).title == "暂不支持"
        )
    }

    @Test("unknown persisted values fail closed")
    func unknownValue() throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set(
            "future-installed-state",
            forKey: "TodoAgent.terminalStatusAuthorization.cursor"
        )
        #expect(TerminalStatusAuthorization.state(for: .cursor, defaults: defaults) == .notAuthorized)
    }

    private func isolatedDefaults() throws -> (UserDefaults, String) {
        let suite = "TerminalStatusAuthorizationTests.\(UUID().uuidString)"
        return (try #require(UserDefaults(suiteName: suite)), suite)
    }
}

struct StatusHookFixture {
    let root: URL
    let home: URL
    let support: URL
    let runner: URL

    init() throws {
        root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("todoagent-status-hook-tests-\(UUID().uuidString)", isDirectory: true)
        home = root.appendingPathComponent("home", isDirectory: true)
        support = root.appendingPathComponent("support", isDirectory: true)
        runner = root.appendingPathComponent("todoagent-terminal-runner")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: runner)
        #expect(chmod(runner.path, mode_t(0o700)) == 0)
    }

    var manager: ProviderStatusHookManager {
        ProviderStatusHookManager(
            homeDirectoryURL: home,
            supportDirectoryURL: support,
            runnerExecutableURL: runner,
            // Passed explicitly. The production default reads
            // `CLAUDE_CONFIG_DIR` from the environment, which would send these
            // writes to the developer's real Claude settings file instead of
            // the fixture home whenever that variable happens to be set.
            claudeConfigurationDirectoryURL: nil
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}
