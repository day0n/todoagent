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
        case .runScoped:
            let enabled = authorization == .enabled
            return TerminalStatusAuthorizationPresentation(
                title: enabled ? "已启用 · 按 Session 注入" : authorization.title,
                detail: enabled
                    ? "仅启动 TodoAgent Session 时通过 Claude --settings 注入，不修改 ~/.claude/settings.json。"
                    : "授权后仅为 TodoAgent 启动的 Claude Session 注入临时 Hook；跳过也可正常启动。",
                isHealthy: enabled,
                canInstall: true,
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

    static func requestIfNeeded(for runtime: RuntimeKind) {
        guard state(for: runtime) == .notAuthorized else { return }
        let manager = ProviderStatusHookManager()
        let capability = manager.capability(for: runtime)
        guard capability != .unsupported else {
            set(.skipped, for: runtime)
            return
        }

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
        case .installed, .installedRequiresProviderReview, .runScoped:
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
            "TodoAgent 只在启动本次 Claude Session 时通过 --settings 注入临时 Hook，不修改 ~/.claude/settings.json。Hook 只向 0600 本机 Socket 发送 Session ID 和 active/blocked/completed 状态，不读取终端输出。选择“暂不”仍可启动 Session。"
        case .kiro:
            "Kiro CLI 目前没有稳定的生命周期 Hook 接口。TodoAgent 仍会监督进程启动和退出，不读取终端输出。"
        }
    }

    private static func key(for runtime: RuntimeKind) -> String {
        keyPrefix + runtime.rawValue
    }
}
