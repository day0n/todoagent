import Foundation

enum TaskConversationRole: Equatable, Sendable {
    case system
    case agent
    case user
    case tool
}

struct TaskConversationEntry: Identifiable, Sendable {
    let id: String
    let role: TaskConversationRole
    let title: String?
    let body: String
}

struct TaskConversationSnapshot: Sendable {
    let sessionID: String
    let runtime: String
    let workspace: String
    let entries: [TaskConversationEntry]
}

enum DemoTaskConversation {
    static func snapshot(
        for task: TaskItem,
        session: TaskSessionDescriptor? = nil
    ) -> TaskConversationSnapshot {
        let runtime = session?.runtime ?? task.runtime ?? "Codex"
        let sessionID = session?.sessionID
            ?? "\(runtime.lowercased())-\(task.id.uuidString.prefix(8).lowercased())"
        let workspace = session?.workspace ?? "~/Desktop/todoagent"
        var entries = baseEntries(
            for: task,
            runtime: runtime,
            sessionID: sessionID,
            workspace: workspace
        )

        if task.note.hasPrefix("已回答：") {
            entries.append(
                TaskConversationEntry(
                    id: "user-answer",
                    role: .user,
                    title: nil,
                    body: String(task.note.dropFirst("已回答：".count))
                )
            )
            entries.append(
                TaskConversationEntry(
                    id: "resume",
                    role: .system,
                    title: "会话已续跑",
                    body: "已使用同一个 \(runtime) session 继续执行。"
                )
            )
        }

        if let question = task.needsText {
            entries.append(
                TaskConversationEntry(
                    id: "question",
                    role: .agent,
                    title: "需要你的回答",
                    body: question
                )
            )
        } else if let result = task.resultText {
            entries.append(
                TaskConversationEntry(
                    id: "result",
                    role: .agent,
                    title: "本轮完成",
                    body: result
                )
            )
        } else if task.status == .running {
            entries.append(
                TaskConversationEntry(
                    id: "running",
                    role: .agent,
                    title: nil,
                    body: task.note.isEmpty ? "正在分析任务并继续执行。" : task.note
                )
            )
        }

        return TaskConversationSnapshot(
            sessionID: sessionID,
            runtime: runtime,
            workspace: workspace,
            entries: entries
        )
    }

    private static func baseEntries(
        for task: TaskItem,
        runtime: String,
        sessionID: String,
        workspace: String
    ) -> [TaskConversationEntry] {
        [
            TaskConversationEntry(
                id: "connected",
                role: .system,
                title: "本地会话已连接",
                body: "\(runtime) · \(sessionID) · \(workspace)"
            ),
            TaskConversationEntry(
                id: "request",
                role: .user,
                title: nil,
                body: task.title
            ),
            TaskConversationEntry(
                id: "plan",
                role: .agent,
                title: nil,
                body: "我会先读取当前工作区，确认相关文件和约束，再执行修改并验证结果。"
            ),
            TaskConversationEntry(
                id: "tool-status",
                role: .tool,
                title: "检查工作区",
                body: "$ git status --short\n$ rg --files apps/macos | head\n已读取 SwiftUI App 与 Rust Engine 目录。"
            ),
            TaskConversationEntry(
                id: "tool-work",
                role: .tool,
                title: "执行记录",
                body: task.status == .todo
                    ? "尚未启动本地 CLI。"
                    : "\(runtime) 正在处理任务；所有工具调用与输出会按时间顺序保留在这里。"
            ),
        ]
    }
}
