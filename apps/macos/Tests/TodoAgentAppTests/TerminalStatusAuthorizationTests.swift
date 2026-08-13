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

    @Test("Claude authorization is run scoped and uninstall returns to skipped")
    func claudeRunScopedAuthorization() throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let fixture = try StatusHookFixture()
        defer { fixture.cleanup() }

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

        try TerminalStatusAuthorization.uninstall(
            for: .claude,
            defaults: defaults,
            manager: fixture.manager
        )
        #expect(TerminalStatusAuthorization.state(for: .claude, defaults: defaults) == .skipped)
        #expect(FileManager.default.fileExists(atPath: fixture.home.path) == false)
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
            runnerExecutableURL: runner
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}
