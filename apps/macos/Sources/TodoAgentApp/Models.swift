import Foundation

enum TaskStatus: String, Codable, CaseIterable, Sendable {
    case todo
    case running
    case needsYou = "needs_you"
    case review
    case done

    var title: String {
        switch self {
        case .todo: "待办"
        case .running: "执行中"
        case .needsYou: "需要你"
        case .review: "待确认"
        case .done: "已完成"
        }
    }
}

enum AppLoadState: Equatable, Sendable {
    case loading
    case loaded
    case failed(String)
}

enum AppSheet: Identifiable, Equatable, Sendable {
    case newTask
    case taskSession(UUID)

    var id: String {
        switch self {
        case .newTask: "new-task"
        case let .taskSession(taskID): "task-session-\(taskID.uuidString)"
        }
    }
}

struct TaskSessionDescriptor: Equatable, Sendable {
    let runtime: String
    let workspace: String
    let sessionID: String
}

enum TaskTransitionError: LocalizedError, Equatable, Sendable {
    case invalid(from: TaskStatus, to: TaskStatus)

    var errorDescription: String? {
        switch self {
        case let .invalid(from, to):
            "任务不能从“\(from.title)”直接变为“\(to.title)”。"
        }
    }
}

enum TaskStateMachine {
    static func validate(from: TaskStatus, to: TaskStatus) throws {
        guard from != to else { return }

        let isAllowed = switch (from, to) {
        case (.todo, .running),
             (.running, .todo),
             (.running, .needsYou),
             (.running, .review),
             (.needsYou, .running),
             (.needsYou, .todo),
             (.review, .todo),
             (.review, .done),
             (.done, .todo):
            true
        default:
            false
        }

        guard isAllowed else { throw TaskTransitionError.invalid(from: from, to: to) }
    }
}

enum NeedsKind: String, Codable, Sendable {
    case question
    case blocked
    case failed
}

struct TaskItem: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var listID: UUID?
    var title: String
    var note: String
    var status: TaskStatus
    var dueDate: Date?
    var needsKind: NeedsKind?
    var needsText: String?
    var runtime: String?
    var elapsed: String?
    var resultText: String?
    var diffPreview: String?
    let createdAt: Date
}

struct TodoList: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var name: String
    var colorName: String
    var repositoryPath: String?
}

enum SmartView: String, CaseIterable, Identifiable, Sendable {
    case timeline
    case tasks
    case running
    case done

    var id: Self { self }

    var title: String {
        switch self {
        case .timeline: "时间线"
        case .tasks: "任务"
        case .running: "进行中"
        case .done: "已完成"
        }
    }

    var symbol: String {
        switch self {
        case .timeline: "clock"
        case .tasks: "checklist"
        case .running: "circle.dotted.circle"
        case .done: "checkmark.circle"
        }
    }
}

enum SidebarSelection: Hashable, Sendable {
    case smart(SmartView)
    case list(UUID)
}

struct ChatMessage: Identifiable, Codable, Hashable, Sendable {
    enum Role: String, Codable, Sendable {
        case user
        case todoAgent
    }

    let id: UUID
    let role: Role
    let body: String
    let createdAt: Date
    var taskReference: UUID?
}

struct AppSnapshot: Codable, Equatable, Sendable {
    var lists: [TodoList]
    var tasks: [TaskItem]
    var messages: [ChatMessage]
}

enum BoardBucket: String, CaseIterable, Identifiable, Sendable {
    case today
    case tomorrow
    case dayAfter
    case later

    var id: Self { self }
}
