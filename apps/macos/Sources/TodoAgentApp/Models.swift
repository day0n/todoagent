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

struct GeminiConnectionResult: Codable, Equatable, Sendable {
    let ok: Bool
    let model: String
    let displayName: String
    let version: String
}

// MARK: - TodoAgent Assistant IPC

/// The assistant owns its own state tree. None of these values are part of
/// `AppSnapshot`, which keeps high-frequency streaming updates from invalidating
/// the task board.
struct AssistantStatus: Codable, Equatable, Sendable {
    let configured: Bool
    let available: Bool
    let model: String?
    let reason: String?
}

struct AssistantSessionDescriptor: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let title: String
    let archived: Bool
    let createdAt: String
    let updatedAt: String
    let lastSequence: Int64
    let isRunning: Bool
    /// Informational only. Each new turn may select a different model.
    let lastModel: String?

    init(
        id: String,
        title: String,
        archived: Bool = false,
        createdAt: String = "",
        updatedAt: String = "",
        lastSequence: Int64 = 0,
        isRunning: Bool = false,
        lastModel: String? = nil
    ) {
        self.id = id
        self.title = title
        self.archived = archived
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastSequence = lastSequence
        self.isRunning = isRunning
        self.lastModel = lastModel
    }

    var displayTitle: String {
        let value = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? "新会话" : value
    }

    func updating(
        title: String? = nil,
        archived: Bool? = nil,
        lastSequence: Int64? = nil,
        isRunning: Bool? = nil,
        lastModel: String? = nil
    ) -> Self {
        Self(
            id: id,
            title: title ?? self.title,
            archived: archived ?? self.archived,
            createdAt: createdAt,
            updatedAt: updatedAt,
            lastSequence: lastSequence ?? self.lastSequence,
            isRunning: isRunning ?? self.isRunning,
            lastModel: lastModel ?? self.lastModel
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, archived, createdAt, updatedAt, lastSequence, isRunning, lastModel
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        title = try values.decodeIfPresent(String.self, forKey: .title) ?? ""
        archived = try values.decodeIfPresent(Bool.self, forKey: .archived) ?? false
        createdAt = try values.decodeIfPresent(String.self, forKey: .createdAt) ?? ""
        updatedAt = try values.decodeIfPresent(String.self, forKey: .updatedAt) ?? ""
        lastSequence = try values.decodeIfPresent(Int64.self, forKey: .lastSequence) ?? 0
        isRunning = try values.decodeIfPresent(Bool.self, forKey: .isRunning) ?? false
        lastModel = try values.decodeIfPresent(String.self, forKey: .lastModel)
    }
}

enum AssistantTurnStatus: String, Codable, Equatable, Sendable {
    case queued, running, completed, failed, cancelled, interrupted

    var isRunning: Bool { self == .queued || self == .running }
}

struct AssistantTurn: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let sessionID: String
    let clientMessageID: String?
    let model: String?
    let status: AssistantTurnStatus
    let errorCode: String?
    let errorMessage: String?
    let startedAt: String?
    let endedAt: String?

    init(
        id: String,
        sessionID: String,
        clientMessageID: String? = nil,
        model: String? = nil,
        status: AssistantTurnStatus,
        errorCode: String? = nil,
        errorMessage: String? = nil,
        startedAt: String? = nil,
        endedAt: String? = nil
    ) {
        self.id = id
        self.sessionID = sessionID
        self.clientMessageID = clientMessageID
        self.model = model
        self.status = status
        self.errorCode = errorCode
        self.errorMessage = errorMessage
        self.startedAt = startedAt
        self.endedAt = endedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case sessionID = "sessionId"
        case clientMessageID = "clientMessageId"
        case model, status, errorCode, errorMessage, startedAt, endedAt
    }
}

enum AssistantMessageRole: String, Codable, Equatable, Sendable {
    case user
    case todoAgent = "todoagent"
    case system
    case tool
}

struct AssistantMessage: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let sessionID: String
    let turnID: String?
    let sequence: Int64
    let clientMessageID: String?
    let role: AssistantMessageRole
    let kind: String
    let body: String
    let payloadJSON: String?
    let taskReferences: [UUID]
    let createdAt: String
    let updatedAt: String

    init(
        id: String,
        sessionID: String,
        turnID: String? = nil,
        sequence: Int64,
        clientMessageID: String? = nil,
        role: AssistantMessageRole,
        kind: String = "text",
        body: String,
        payloadJSON: String? = nil,
        taskReferences: [UUID] = [],
        createdAt: String = "",
        updatedAt: String = ""
    ) {
        self.id = id
        self.sessionID = sessionID
        self.turnID = turnID
        self.sequence = sequence
        self.clientMessageID = clientMessageID
        self.role = role
        self.kind = kind
        self.body = body
        self.payloadJSON = payloadJSON
        self.taskReferences = taskReferences
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case sessionID = "sessionId"
        case turnID = "turnId"
        case sequence
        case clientMessageID = "clientMessageId"
        case role, kind, body
        case payloadJSON = "payloadJson"
        case taskReferences, createdAt, updatedAt
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        sessionID = try values.decode(String.self, forKey: .sessionID)
        turnID = try values.decodeIfPresent(String.self, forKey: .turnID)
        sequence = try values.decode(Int64.self, forKey: .sequence)
        clientMessageID = try values.decodeIfPresent(String.self, forKey: .clientMessageID)
        role = try values.decode(AssistantMessageRole.self, forKey: .role)
        kind = try values.decodeIfPresent(String.self, forKey: .kind) ?? "text"
        body = try values.decodeIfPresent(String.self, forKey: .body) ?? ""
        payloadJSON = try values.decodeIfPresent(String.self, forKey: .payloadJSON)
        taskReferences = try values.decodeIfPresent([UUID].self, forKey: .taskReferences) ?? []
        createdAt = try values.decodeIfPresent(String.self, forKey: .createdAt) ?? ""
        updatedAt = try values.decodeIfPresent(String.self, forKey: .updatedAt) ?? ""
    }

    var textAttachments: [AssistantAttachmentSummary] {
        AssistantAttachmentPayload.decode(from: payloadJSON)
    }
}

struct AssistantTextAttachment: Codable, Equatable, Sendable {
    let name: String
    let mediaType: String
    let content: String
    let byteCount: Int
}

struct AssistantAttachmentSummary: Codable, Equatable, Sendable {
    let name: String
    let mediaType: String
    let byteCount: Int
}

private struct AssistantAttachmentPayload: Decodable {
    let attachments: [AssistantAttachmentSummary]

    static func decode(from payloadJSON: String?) -> [AssistantAttachmentSummary] {
        guard
            let payloadJSON,
            let data = payloadJSON.data(using: .utf8),
            let payload = try? JSONDecoder().decode(Self.self, from: data)
        else { return [] }
        return payload.attachments
    }
}

struct AssistantSessionBundle: Codable, Equatable, Sendable {
    let session: AssistantSessionDescriptor
    let messages: [AssistantMessage]
    let tools: [AssistantPersistedTool]
    let activeTurn: AssistantTurn?

    init(
        session: AssistantSessionDescriptor,
        messages: [AssistantMessage] = [],
        tools: [AssistantPersistedTool] = [],
        activeTurn: AssistantTurn? = nil
    ) {
        self.session = session
        self.messages = messages
        self.tools = tools
        self.activeTurn = activeTurn
    }

    private enum CodingKeys: String, CodingKey { case session, messages, tools, activeTurn }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        session = try values.decode(AssistantSessionDescriptor.self, forKey: .session)
        messages = try values.decodeIfPresent([AssistantMessage].self, forKey: .messages) ?? []
        tools = try values.decodeIfPresent([AssistantPersistedTool].self, forKey: .tools) ?? []
        activeTurn = try values.decodeIfPresent(AssistantTurn.self, forKey: .activeTurn)
    }
}

/// Stable tool projection returned by `assistant.history`. Live tool events use
/// the smaller event DTOs below, while this record rebuilds the same UI after an
/// Engine or App restart.
struct AssistantPersistedTool: Codable, Equatable, Sendable {
    let id: String
    let sessionID: String
    let turnID: String?
    let callID: String
    let toolName: String
    let taskRefsJSON: String?
    let isError: Bool
    let status: String

    private enum CodingKeys: String, CodingKey {
        case id
        case sessionID = "sessionId"
        case turnID = "turnId"
        case callID = "callId"
        case toolName, taskRefsJSON = "taskRefsJson", isError, status
    }

    var taskReferences: [UUID] {
        guard
            let taskRefsJSON,
            let data = taskRefsJSON.data(using: .utf8),
            let values = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return values.compactMap(UUID.init(uuidString:))
    }

    var activity: AssistantToolActivity? {
        guard let turnID else { return nil }
        let state: AssistantToolState = switch status {
        case "queued", "running": .running
        case "completed" where !isError: .completed
        default: .failed
        }
        return AssistantToolActivity(
            sessionID: sessionID,
            turnID: turnID,
            toolCallID: callID,
            name: toolName,
            state: state,
            taskReferences: taskReferences
        )
    }
}

struct AssistantStreamingDraft: Equatable, Sendable {
    let sessionID: String
    let turnID: String
    let messageID: String
    var attempt: Int
    var body: String
}

enum AssistantToolState: Equatable, Sendable { case running, completed, failed }

struct AssistantToolActivity: Identifiable, Equatable, Sendable {
    var id: String { toolCallID }
    let sessionID: String
    let turnID: String
    let toolCallID: String
    let name: String
    var state: AssistantToolState
    var taskReferences: [UUID]
}

enum AssistantLoadState: Equatable, Sendable { case idle, loading, loaded, failed(String) }

// MARK: Assistant request/response payloads

struct AssistantEmptyRequest: Encodable, Sendable {}
struct AssistantSessionListRequest: Encodable, Sendable { let includeArchived: Bool }
struct AssistantSessionCreateRequest: Encodable, Sendable { let title: String? }
struct AssistantSessionRenameRequest: Encodable, Sendable {
    let sessionID: String
    let title: String
    private enum CodingKeys: String, CodingKey { case sessionID = "sessionId"; case title }
}
struct AssistantSessionArchiveRequest: Encodable, Sendable {
    let sessionID: String
    private enum CodingKeys: String, CodingKey { case sessionID = "sessionId" }
}
struct AssistantHistoryRequest: Encodable, Sendable {
    let sessionID: String
    let afterSequence: Int64
    let limit: Int
    private enum CodingKeys: String, CodingKey {
        case sessionID = "sessionId"
        case afterSequence, limit
    }
}
struct AssistantSendRequest: Encodable, Sendable {
    let sessionID: String
    let clientMessageID: UUID
    let text: String
    let model: String
    let attachments: [AssistantTextAttachment]
    private enum CodingKeys: String, CodingKey {
        case sessionID = "sessionId"
        case clientMessageID = "clientMessageId"
        case text, model, attachments
    }
}
struct AssistantCancelTurnRequest: Encodable, Sendable {
    let sessionID: String
    private enum CodingKeys: String, CodingKey { case sessionID = "sessionId" }
}

struct AssistantSessionListResponse: Decodable, Sendable { let sessions: [AssistantSessionDescriptor] }

/// Create/rename/archive may return either a descriptor or a complete bundle.
/// This one decoding boundary keeps the rest of the app independent of that
/// transport detail while Rust settles on its final response size.
struct AssistantSessionResponse: Decodable, Sendable {
    let bundle: AssistantSessionBundle

    private enum CodingKeys: String, CodingKey { case session, messages, tools, activeTurn }

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if let bundle = try? value.decode(AssistantSessionBundle.self) {
            self.bundle = bundle
        } else if let session = try? value.decode(AssistantSessionDescriptor.self) {
            bundle = AssistantSessionBundle(session: session)
        } else {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            let session = try values.decode(AssistantSessionDescriptor.self, forKey: .session)
            bundle = AssistantSessionBundle(
                session: session,
                messages: try values.decodeIfPresent([AssistantMessage].self, forKey: .messages) ?? [],
                tools: try values.decodeIfPresent([AssistantPersistedTool].self, forKey: .tools) ?? [],
                activeTurn: try values.decodeIfPresent(AssistantTurn.self, forKey: .activeTurn)
            )
        }
    }
}

// MARK: Assistant event payloads

struct AssistantSessionChangedEvent: Decodable, Sendable { let session: AssistantSessionDescriptor }
struct AssistantTurnEvent: Decodable, Sendable {
    let sessionID: String
    let turn: AssistantTurn
    private enum CodingKeys: String, CodingKey { case sessionID = "sessionId"; case turn }
}
struct AssistantMessageDeltaEvent: Decodable, Sendable {
    let sessionID: String
    let turnID: String
    let messageID: String
    let attempt: Int?
    let delta: String
    private enum CodingKeys: String, CodingKey {
        case sessionID = "sessionId"
        case turnID = "turnId"
        case messageID = "messageId"
        case attempt, delta
    }
}
struct AssistantMessageAppendedEvent: Decodable, Sendable {
    let sessionID: String
    let message: AssistantMessage
    private enum CodingKeys: String, CodingKey { case sessionID = "sessionId"; case message }
}
struct AssistantToolStartedEvent: Decodable, Sendable {
    let sessionID: String
    let turnID: String
    let toolCallID: String
    let name: String
    private enum CodingKeys: String, CodingKey {
        case sessionID = "sessionId"
        case turnID = "turnId"
        case toolCallID = "toolCallId"
        case name
    }
}
struct AssistantToolFinishedEvent: Decodable, Sendable {
    let sessionID: String
    let turnID: String
    let toolCallID: String
    let name: String
    let isError: Bool
    let taskReferences: [UUID]

    private enum CodingKeys: String, CodingKey {
        case sessionID = "sessionId"
        case turnID = "turnId"
        case toolCallID = "toolCallId"
        case name, isError, taskReferences
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        sessionID = try values.decode(String.self, forKey: .sessionID)
        turnID = try values.decode(String.self, forKey: .turnID)
        toolCallID = try values.decode(String.self, forKey: .toolCallID)
        name = try values.decode(String.self, forKey: .name)
        isError = try values.decodeIfPresent(Bool.self, forKey: .isError) ?? false
        taskReferences = try values.decodeIfPresent([UUID].self, forKey: .taskReferences) ?? []
    }
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

    private enum CodingKeys: String, CodingKey {
        case id
        case taskID = "taskId"
        case runtimeKind, workingDirectory
        case providerSessionID = "providerSessionId"
        case providerEngine, state, lastAgentSequence, lastReadSequence
        case lastErrorCode, lastErrorMessage, createdAt, updatedAt
    }
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

    private enum CodingKeys: String, CodingKey {
        case id
        case sessionID = "sessionId"
        case ordinal
        case userMessageID = "userMessageId"
        case providerSessionIDBefore = "providerSessionIdBefore"
        case providerSessionIDAfter = "providerSessionIdAfter"
        case status, exitCode, finalOutput, errorCode, errorMessage
        case providerUsageJSON = "providerUsageJson"
        case startedAt, endedAt, createdAt
    }
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

    private enum CodingKeys: String, CodingKey {
        case id
        case sessionID = "sessionId"
        case turnID = "turnId"
        case sequence
        case clientMessageID = "clientMessageId"
        case role, kind, body
        case payloadJSON = "payloadJson"
        case createdAt, updatedAt
    }
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
