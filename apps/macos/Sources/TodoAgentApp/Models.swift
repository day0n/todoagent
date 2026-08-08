import Foundation

enum TaskStatus: String, Codable, CaseIterable, Sendable {
    case open
    case completed

    var title: String { self == .open ? "未完成" : "已完成" }
}

enum RuntimeKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case codex, claude, cursor, kiro

    var id: Self { self }
    var title: String {
        switch self {
        case .codex: "Codex"
        case .claude: "Claude Code"
        case .cursor: "Cursor Agent"
        case .kiro: "Kiro CLI"
        }
    }
}

enum RuntimeAvailability: String, Codable, Sendable {
    case ready
    case authRequired = "auth_required"
    case detected
    case missing
    case error
}

struct RuntimeInfo: Identifiable, Codable, Equatable, Sendable {
    var id: RuntimeKind { kind }
    let kind: RuntimeKind
    let launchPath: String?
    let resolvedPath: String?
    let version: String?
    let status: RuntimeAvailability
    let authStatus: String
    let capabilities: [String: JSONValue]
    let providerEngine: String?
    let detectedAt: String?
    let verifiedAt: String?
    let verifyError: String?

    var isSelectable: Bool { status == .ready }
}

enum JSONValue: Codable, Equatable, Sendable {
    case string(String), number(Double), bool(Bool), object([String: JSONValue]), array([JSONValue]), null

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let decoded = try? value.decode(Bool.self) { self = .bool(decoded) }
        else if let decoded = try? value.decode(Double.self) { self = .number(decoded) }
        else if let decoded = try? value.decode(String.self) { self = .string(decoded) }
        else if let decoded = try? value.decode([String: JSONValue].self) { self = .object(decoded) }
        else { self = .array(try value.decode([JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case let .string(item): try value.encode(item)
        case let .number(item): try value.encode(item)
        case let .bool(item): try value.encode(item)
        case let .object(item): try value.encode(item)
        case let .array(item): try value.encode(item)
        case .null: try value.encodeNil()
        }
    }
}

enum SessionState: String, Codable, Sendable {
    case idle, queued, running, failed, closed
    var isBusy: Bool { self == .queued || self == .running }
}

enum TurnStatus: String, Codable, Sendable {
    case queued, running, completed, failed, cancelled, interrupted
}

enum SessionMessageRole: String, Codable, Sendable {
    case user, agent, system, tool
}

struct TaskSessionDescriptor: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let taskID: UUID
    let runtimeKind: RuntimeKind
    let workingDirectory: String
    let providerSessionID: String?
    let providerEngine: String?
    let state: SessionState
    let lastAgentSequence: Int64
    let lastReadSequence: Int64
    let lastErrorCode: String?
    let lastErrorMessage: String?
    let createdAt: String
    let updatedAt: String

    var hasUnread: Bool { lastAgentSequence > lastReadSequence }
}

struct SessionTurn: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let sessionID: String
    let ordinal: Int64
    let userMessageID: String
    let providerSessionIDBefore: String?
    let providerSessionIDAfter: String?
    let status: TurnStatus
    let exitCode: Int?
    let finalOutput: String?
    let errorCode: String?
    let errorMessage: String?
    let providerUsageJSON: String?
    let startedAt: String?
    let endedAt: String?
    let createdAt: String
}

struct SessionMessage: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let sessionID: String
    let turnID: String?
    let sequence: Int64
    let clientMessageID: String?
    let role: SessionMessageRole
    let kind: String
    let body: String
    let payloadJSON: String?
    let createdAt: String
    let updatedAt: String
}

struct SessionBundle: Codable, Equatable, Sendable {
    let session: TaskSessionDescriptor
    let messages: [SessionMessage]
    let activeTurn: SessionTurn?
}

enum AppLoadState: Equatable, Sendable { case loading, loaded, failed(String) }

enum AppSheet: Identifiable, Equatable, Sendable {
    case newTask
    case taskSession(UUID)
    var id: String {
        switch self {
        case .newTask: "new-task"
        case let .taskSession(id): "task-session-\(id)"
        }
    }
}

struct TaskItem: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var listID: UUID?
    var title: String
    var note: String
    var status: TaskStatus
    var dueDate: Date?
    var completedAt: String?
    let createdAt: Date
    var updatedAt: String
}

struct TodoList: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var name: String
    var colorName: String
    var repositoryPath: String?
}

enum SmartView: String, CaseIterable, Identifiable, Sendable {
    case timeline, tasks, running, done
    var id: Self { self }
    var title: String {
        switch self { case .timeline: "时间线"; case .tasks: "任务"; case .running: "进行中"; case .done: "已完成" }
    }
    var symbol: String {
        switch self { case .timeline: "clock"; case .tasks: "checklist"; case .running: "circle.dotted.circle"; case .done: "checkmark.circle" }
    }
}

enum SidebarSelection: Hashable, Sendable { case smart(SmartView), list(UUID) }

struct ChatMessage: Identifiable, Codable, Hashable, Sendable {
    enum Role: String, Codable, Sendable { case user, todoAgent }
    let id: UUID
    let role: Role
    let body: String
    let createdAt: Date
    var taskReference: UUID?
}

struct AppSnapshot: Codable, Equatable, Sendable {
    var revision: Int64
    var lists: [TodoList]
    var tasks: [TaskItem]
    var runtimes: [RuntimeInfo]
    var sessions: [TaskSessionDescriptor]
    var messages: [ChatMessage]
}

enum BoardBucket: String, CaseIterable, Identifiable, Sendable { case today, tomorrow, dayAfter, later; var id: Self { self } }
