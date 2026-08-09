import AppKit
import Foundation

@MainActor
enum ExecutionSafety {
    private static let consentKey = "TodoAgent.executionConsentVersion"
    private static let consentVersion = 1

    static func authorize(runtime: RuntimeKind) -> Bool {
        if UserDefaults.standard.integer(forKey: consentKey) < consentVersion {
            let alert = NSAlert()
            alert.messageText = "允许本地 Agent 自动执行？"
            alert.informativeText = "Codex、Claude Code、Cursor Agent 和 Kiro CLI 可以在你选择的目录中直接修改文件并运行命令。TodoAgent 不会自动提交、合并或创建隐藏工作区。Cursor 的消息按官方契约放在启动参数中，可能短暂出现在本机进程列表。"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "我了解并继续")
            alert.addButton(withTitle: "取消")
            guard alert.runModal() == .alertFirstButtonReturn else { return false }
            UserDefaults.standard.set(consentVersion, forKey: consentKey)
        }
        return true
    }
}
