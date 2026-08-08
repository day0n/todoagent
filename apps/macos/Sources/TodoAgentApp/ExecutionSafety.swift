import AppKit
import Foundation

struct WorkspaceGitState: Sendable {
    let isRepository: Bool
    let dirtySummary: String
}

@MainActor
enum ExecutionSafety {
    private static let consentKey = "TodoAgent.executionConsentVersion"
    private static let consentVersion = 1

    static func authorize(runtime: RuntimeKind, workspace: String) async -> Bool {
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

        let git = await inspectGit(workspace)
        let alert = NSAlert()
        alert.alertStyle = .warning
        if git.isRepository, !git.dirtySummary.isEmpty {
            alert.messageText = "这个工作区已有未提交改动"
            alert.informativeText = "这些改动可能与 \(runtime.title) 新产生的修改混在一起。\n\n\(git.dirtySummary)"
        } else if !git.isRepository {
            alert.messageText = "这不是 Git 工作区"
            alert.informativeText = "TodoAgent 无法区分运行前已有文件与 Agent 新产生的修改。"
        } else {
            return true
        }
        alert.addButton(withTitle: "仍然启动")
        alert.addButton(withTitle: "取消")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private static func inspectGit(_ workspace: String) async -> WorkspaceGitState {
        await Task.detached(priority: .userInitiated) {
            let process = Process()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", workspace, "status", "--porcelain=v1", "--untracked-files=normal"]
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else { return WorkspaceGitState(isRepository: false, dirtySummary: "") }
                let data = output.fileHandleForReading.readDataToEndOfFile()
                let lines = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline)
                let summary = lines.prefix(20).joined(separator: "\n")
                return WorkspaceGitState(isRepository: true, dirtySummary: summary)
            } catch {
                return WorkspaceGitState(isRepository: false, dirtySummary: "")
            }
        }.value
    }
}
