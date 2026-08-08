import Foundation

protocol AppRepository: Sendable {
    func load() async throws -> AppSnapshot
    func createTask(title: String, listID: UUID?, dueDate: Date?) async throws -> AppSnapshot
    func setStatus(taskID: UUID, status: TaskStatus) async throws -> AppSnapshot
    func answer(taskID: UUID, text: String) async throws -> AppSnapshot
    func cancel(taskID: UUID) async throws -> AppSnapshot
    func sendChat(_ text: String) async throws -> AppSnapshot
}

enum AppRepositoryError: LocalizedError, Equatable, Sendable {
    case taskNotFound

    var errorDescription: String? {
        switch self {
        case .taskNotFound: "找不到这个任务，它可能已经被删除。"
        }
    }
}

private enum DemoID {
    static let productList = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
    static let ideasList = UUID(uuidString: "00000000-0000-4000-8000-000000000002")!
    static let runningTask = UUID(uuidString: "00000000-0000-4000-8000-000000000101")!
    static let questionTask = UUID(uuidString: "00000000-0000-4000-8000-000000000102")!
    static let reviewTask = UUID(uuidString: "00000000-0000-4000-8000-000000000103")!
    static let todoTask = UUID(uuidString: "00000000-0000-4000-8000-000000000104")!
    static let doneTask = UUID(uuidString: "00000000-0000-4000-8000-000000000105")!
    static let greetingMessage = UUID(uuidString: "00000000-0000-4000-8000-000000000201")!
    static let requestMessage = UUID(uuidString: "00000000-0000-4000-8000-000000000202")!
    static let responseMessage = UUID(uuidString: "00000000-0000-4000-8000-000000000203")!
}

actor DemoRepository: AppRepository {
    private var snapshot: AppSnapshot

    init(now: Date = .now) {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)
        let dayAfter = calendar.date(byAdding: .day, value: 2, to: today)

        let product = TodoList(id: DemoID.productList, name: "TodoAgent", colorName: "blue", repositoryPath: "~/Desktop/todoagent")
        let ideas = TodoList(id: DemoID.ideasList, name: "灵光一现", colorName: "orange", repositoryPath: nil)

        let running = TaskItem(
            id: DemoID.runningTask, listID: product.id, title: "实现原生 macOS 预览版",
            note: "Codex 正在搭建 SwiftUI 三栏界面", status: .running,
            dueDate: today, needsKind: nil, needsText: nil, runtime: "Codex",
            elapsed: "3 分钟", resultText: nil, diffPreview: nil, createdAt: now
        )
        let question = TaskItem(
            id: DemoID.questionTask, listID: product.id, title: "确定 DMG 首次发布范围",
            note: "Agent 需要一个产品决策", status: .needsYou,
            dueDate: today, needsKind: .question, needsText: "第一版是否只支持 Apple Silicon？",
            runtime: "Claude", elapsed: "1 分钟", resultText: nil, diffPreview: nil, createdAt: now
        )
        let review = TaskItem(
            id: DemoID.reviewTask, listID: product.id, title: "修复运行时 PATH 检测",
            note: "已修改 4 个文件，等待人工确认", status: .review,
            dueDate: tomorrow, needsKind: nil, needsText: nil, runtime: "Codex",
            elapsed: "6 分钟",
            resultText: "已补齐 Finder 启动时的 PATH，并验证 Codex 与 Claude 均可发现。",
            diffPreview: "+ resolve Homebrew and ~/.local/bin\n+ preserve executable snapshots\n+ add runtime verification tests",
            createdAt: now
        )
        let todo = TaskItem(
            id: DemoID.todoTask, listID: ideas.id, title: "设计首次启动引导",
            note: "说明 CLI、仓库权限与人工确认", status: .todo,
            dueDate: dayAfter, needsKind: nil, needsText: nil, runtime: nil,
            elapsed: nil, resultText: nil, diffPreview: nil, createdAt: now
        )
        let done = TaskItem(
            id: DemoID.doneTask, listID: product.id, title: "确认原生重构技术路线",
            note: "SwiftUI + Rust Engine sidecar", status: .done,
            dueDate: today, needsKind: nil, needsText: nil, runtime: nil,
            elapsed: nil, resultText: "技术路线已确认。", diffPreview: nil, createdAt: now
        )

        snapshot = AppSnapshot(
            lists: [product, ideas],
            tasks: [running, question, review, todo, done],
            messages: [
                ChatMessage(
                    id: DemoID.greetingMessage, role: .todoAgent,
                    body: "下午好。我会帮你整理任务、调用本机 CLI，并把结果留给你确认。",
                    createdAt: now.addingTimeInterval(-240), taskReference: nil
                ),
                ChatMessage(
                    id: DemoID.requestMessage, role: .user,
                    body: "把原生 Mac 版的工作整理一下。",
                    createdAt: now.addingTimeInterval(-180), taskReference: nil
                ),
                ChatMessage(
                    id: DemoID.responseMessage, role: .todoAgent,
                    body: "已经整理成任务，并将 SwiftUI 预览版放在今天。",
                    createdAt: now.addingTimeInterval(-150), taskReference: running.id
                ),
            ]
        )
    }

    func load() async throws -> AppSnapshot { snapshot }

    func createTask(title: String, listID: UUID?, dueDate: Date?) async throws -> AppSnapshot {
        snapshot.tasks.insert(
            TaskItem(
                id: UUID(), listID: listID, title: title, note: "", status: .todo,
                dueDate: dueDate, needsKind: nil, needsText: nil, runtime: nil,
                elapsed: nil, resultText: nil, diffPreview: nil, createdAt: .now
            ),
            at: 0
        )
        return snapshot
    }

    func setStatus(taskID: UUID, status: TaskStatus) async throws -> AppSnapshot {
        guard let index = snapshot.tasks.firstIndex(where: { $0.id == taskID }) else {
            throw AppRepositoryError.taskNotFound
        }
        try TaskStateMachine.validate(from: snapshot.tasks[index].status, to: status)
        snapshot.tasks[index].status = status
        if status != .needsYou {
            snapshot.tasks[index].needsKind = nil
            snapshot.tasks[index].needsText = nil
        }
        if status == .running {
            snapshot.tasks[index].runtime = snapshot.tasks[index].runtime ?? "Codex"
            snapshot.tasks[index].elapsed = "刚刚"
        }
        return snapshot
    }

    func answer(taskID: UUID, text: String) async throws -> AppSnapshot {
        guard let index = snapshot.tasks.firstIndex(where: { $0.id == taskID }) else {
            throw AppRepositoryError.taskNotFound
        }
        try TaskStateMachine.validate(from: snapshot.tasks[index].status, to: .running)
        snapshot.tasks[index].status = .running
        snapshot.tasks[index].needsKind = nil
        snapshot.tasks[index].needsText = nil
        snapshot.tasks[index].note = "已回答：\(text)"
        return snapshot
    }

    func cancel(taskID: UUID) async throws -> AppSnapshot {
        try await setStatus(taskID: taskID, status: .todo)
    }

    func sendChat(_ text: String) async throws -> AppSnapshot {
        snapshot.messages.append(ChatMessage(id: UUID(), role: .user, body: text, createdAt: .now, taskReference: nil))
        snapshot.messages.append(
            ChatMessage(
                id: UUID(), role: .todoAgent,
                body: "收到。预览模式不会启动真实 CLI；我已把这条消息保留在本次演示会话中。",
                createdAt: .now, taskReference: nil
            )
        )
        return snapshot
    }
}
