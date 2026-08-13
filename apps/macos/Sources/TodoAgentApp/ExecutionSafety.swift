import AppKit
import Foundation

@MainActor
enum ExecutionSafety {
    private static let consentKey = "TodoAgent.executionConsentVersion"
    private static let consentVersion = 2

    static func authorize(runtime: RuntimeKind) -> Bool {
        if UserDefaults.standard.integer(forKey: consentKey) < consentVersion {
            let alert = NSAlert()
            alert.messageText = "允许本地 Agent 终端执行？"
            alert.informativeText = "TodoAgent 会在真实 PTY 中直接启动 Codex、Claude Code、Cursor Agent 或 Kiro CLI。你在终端里输入的命令，以及 Agent 获准调用的工具，都能在所选目录中修改文件、运行程序和访问该 CLI 本身拥有的网络能力。TodoAgent 不解析或限制终端命令，也不会自动提交、合并或创建隐藏工作区。"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "我了解并继续")
            alert.addButton(withTitle: "取消")
            guard alert.runModal() == .alertFirstButtonReturn else { return false }
            UserDefaults.standard.set(consentVersion, forKey: consentKey)
        }
        return true
    }
}
