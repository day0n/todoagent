import AppKit
import Foundation

enum TerminalStatusAuthorizationState: String, Codable, Sendable {
    case notAuthorized = "not_authorized"
    case skipped
    case enabled

    var title: String {
        switch self {
        case .notAuthorized: "未授权"
        case .skipped: "已跳过"
        case .enabled: "已授权"
        }
    }
}

struct TerminalStatusAuthorizationPresentation: Equatable, Sendable {
    let title: String
    let detail: String
    let isHealthy: Bool
    let canInstall: Bool
    let canUninstall: Bool
}

/// Persists consent independently per runtime and performs the corresponding
/// provider integration before recording it as enabled. Runner start/exit
/// supervision remains mandatory protocol behavior and is not controlled here.
@MainActor
enum TerminalStatusAuthorization {
    private static let keyPrefix = "TodoAgent.terminalStatusAuthorization."

    static func state(
        for runtime: RuntimeKind,
        defaults: UserDefaults = .standard
    ) -> TerminalStatusAuthorizationState {
        guard let rawValue = defaults.string(forKey: key(for: runtime)) else {
            return .notAuthorized
        }
        return TerminalStatusAuthorizationState(rawValue: rawValue) ?? .notAuthorized
    }

    static func set(
        _ state: TerminalStatusAuthorizationState,
        for runtime: RuntimeKind,
        defaults: UserDefaults = .standard
    ) {
        defaults.set(state.rawValue, forKey: key(for: runtime))
    }

    static func presentation(
        for runtime: RuntimeKind,
        defaults: UserDefaults = .standard,
        manager: ProviderStatusHookManager = ProviderStatusHookManager()
    ) -> TerminalStatusAuthorizationPresentation {
        let authorization = state(for: runtime, defaults: defaults)
        let inspection = manager.inspect(runtime: runtime)
        switch inspection.health {
        case .unsupported:
            return TerminalStatusAuthorizationPresentation(
                title: "暂不支持",
                detail: "Kiro CLI 目前没有稳定的生命周期 Hook 接口；TodoAgent 仍会监督进程启动和退出。",
                isHealthy: false,
                canInstall: false,
                canUninstall: authorization != .notAuthorized
            )
        case .installedRequiresProviderReview:
            let enabled = authorization == .enabled
            return TerminalStatusAuthorizationPresentation(
                title: enabled ? "已安装 · 待 Codex 信任" : authorization.title,
                detail: "Codex 会校验 Hook 定义；首次使用请在 Codex 中打开 /hooks，检查并信任 TodoAgent Hook。",
                isHealthy: enabled,
                canInstall: true,
                canUninstall: true
            )
        case .installed:
            let enabled = authorization == .enabled
            return TerminalStatusAuthorizationPresentation(
                title: enabled ? "已安装" : authorization.title,
                detail: "已合并到当前账户的用户级 Hook；TodoAgent 之外运行时不会发送状态。",
                isHealthy: enabled,
                canInstall: true,
                canUninstall: true
            )
        case .notInstalled:
            return TerminalStatusAuthorizationPresentation(
                title: authorization == .enabled ? "需要重新安装" : authorization.title,
                detail: "尚未在用户级配置中找到完整的 TodoAgent Hook。",
                isHealthy: false,
                canInstall: true,
                canUninstall: authorization != .notAuthorized
            )
        case let .needsRepair(message):
            return TerminalStatusAuthorizationPresentation(
                title: authorization == .enabled ? "需要修复" : authorization.title,
                detail: message,
                isHealthy: false,
                canInstall: manager.capability(for: runtime) != .unsupported,
                canUninstall: authorization != .notAuthorized
            )
        }
    }

    /// Whether the consent prompt should be shown.
    ///
    /// Beyond a first-time decision, this re-asks when the stored state claims
    /// `enabled` while nothing is actually installed. Two cases reach that: an
    /// install undone outside TodoAgent, and an account that recorded `enabled`
    /// under the older Claude integration, which injected `--settings` per Run
    /// and wrote nothing to disk — so its stored `enabled` describes a promise
    /// that no longer holds. Consent is re-requested rather than acted on
    /// silently, because merging into the user's `settings.json` is a broader
    /// action than the earlier prompt described.
    ///
    /// `skipped` is never reopened: a declined prompt stays declined.
    static func needsConsentPrompt(
        state: TerminalStatusAuthorizationState,
        health: ProviderStatusHookHealth
    ) -> Bool {
        switch state {
        case .notAuthorized:
            true
        case .skipped:
            false
        case .enabled:
            // `needsRepair` counts here because a missing wrapper is reported
            // before the configuration is even read, which is exactly the state
            // an account upgraded from the run-scoped integration is in.
            switch health {
            case .notInstalled: true
            case .needsRepair: true
            case .installed, .installedRequiresProviderReview, .unsupported: false
            }
        }
    }

    static func requestIfNeeded(for runtime: RuntimeKind) {
        let manager = ProviderStatusHookManager()
        guard needsConsentPrompt(
            state: state(for: runtime),
            health: manager.inspect(runtime: runtime).health
        ) else { return }
        let capability = manager.capability(for: runtime)
        guard capability != .unsupported else {
            set(.skipped, for: runtime)
            return
        }
        // Without the bundled runner an install cannot succeed, and a failed
        // install resets the state to `notAuthorized` — which would re-prompt on
        // the next terminal, forever. This happens in `swift run` builds, where
        // the runner is not staged beside the executable.
        guard manager.runnerExecutableURL != nil else { return }

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "允许 \(runtime.title) 报告 Session 状态？"
        alert.informativeText = consentDescription(for: runtime)
        alert.addButton(withTitle: capability == .globalUserConfiguration ? "安装并启用" : "启用")
        alert.addButton(withTitle: "暂不")
        guard alert.runModal() == .alertFirstButtonReturn else {
            set(.skipped, for: runtime)
            return
        }
        do {
            try enable(for: runtime, manager: manager)
        } catch {
            set(.notAuthorized, for: runtime)
            let failure = NSAlert(error: error)
            failure.messageText = "无法启用 \(runtime.title) 状态集成"
            failure.runModal()
        }
    }

    static func enable(
        for runtime: RuntimeKind,
        defaults: UserDefaults = .standard,
        manager: ProviderStatusHookManager = ProviderStatusHookManager()
    ) throws {
        guard manager.capability(for: runtime) != .unsupported else {
            throw ProviderStatusHookError.unsupportedRuntime(runtime)
        }
        let inspection = try manager.install(runtime: runtime)
        switch inspection.health {
        case .installed, .installedRequiresProviderReview:
            set(.enabled, for: runtime, defaults: defaults)
        case .notInstalled, .unsupported, .needsRepair:
            throw ProviderStatusHookError.malformedConfiguration(
                inspection.configurationPath ?? runtime.title
            )
        }
    }

    static func uninstall(
        for runtime: RuntimeKind,
        defaults: UserDefaults = .standard,
        manager: ProviderStatusHookManager = ProviderStatusHookManager()
    ) throws {
        try manager.uninstall(runtime: runtime)
        set(.skipped, for: runtime, defaults: defaults)
    }

    static func consentDescription(for runtime: RuntimeKind) -> String {
        switch runtime {
        case .codex:
            "TodoAgent 会备份并合并 ~/.codex/hooks.json，安装只向当前 Session 的 0600 本机 Socket 发送 Session ID 和 active/completed 状态的 Hook；Codex 的审批阻塞状态不会被推测。不会读取终端输出；其他 Hook 会保留。Codex 首次运行还会要求你在 /hooks 中检查并信任。选择“暂不”仍可启动 Session。"
        case .cursor:
            "TodoAgent 会备份并合并 ~/.cursor/hooks.json，安装只向当前 Session 的 0600 本机 Socket 发送 conversation ID 和 active/completed 状态的 Hook；Cursor 的审批阻塞状态不会被推测。不会读取终端输出；其他 Hook 会保留。选择“暂不”仍可启动 Session。"
        case .claude:
            "TodoAgent 会备份并合并 ~/.claude/settings.json（若设置了 CLAUDE_CONFIG_DIR 则用该目录），安装只向当前 Session 的 0600 本机 Socket 发送 Session ID 和 active/blocked/completed 状态的 Hook。不会读取终端输出；你已有的 Hook 和其他设置都会保留，可随时卸载。这样你在任务终端里自己启动的 claude 也能回报状态。选择“暂不”仍可启动 Session。"
        case .kiro:
            "Kiro CLI 目前没有稳定的生命周期 Hook 接口。TodoAgent 仍会监督进程启动和退出，不读取终端输出。"
        }
    }

    private static func key(for runtime: RuntimeKind) -> String {
        keyPrefix + runtime.rawValue
    }
}
